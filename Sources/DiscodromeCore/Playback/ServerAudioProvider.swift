import AVFoundation
import CryptoKit
import Foundation
import Synchronization

public enum PlaybackError: LocalizedError {
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case .undecodable(let title): return "“\(title)” is in a format this Mac can't decode."
        }
    }
}

/// Fetches server tracks into an on-disk cache for the gapless engine. FLAC and AIFF songs start
/// playing as soon as their beginning has arrived, other formats once downloaded. Original bytes
/// where Core Audio decodes them; otherwise the server transcodes to MP3.
public final class ServerAudioProvider: AudioFileProvider {
    /// Formats Core Audio decodes on current macOS.
    public static let nativeSuffixes: Set<String> = [
        "flac", "mp3", "m4a", "mp4", "aac", "alac", "wav", "aif", "aiff", "aifc", "caf", "ogg", "oga", "opus",
    ]
    /// Formats that play while they download: a partial file decodes exactly up to where its data
    /// stops, and reopened later resumes on the same sample. The rest wait for the whole file — an
    /// .m4a won't open before, Opus resumes slightly off, a WAV's length is a guess until the end,
    /// and MP3 hasn't been verified.
    static let progressiveSuffixes: Set<String> = ["flac", "aif", "aiff", "aifc"]

    public let directory: URL
    private let client: SubsonicClient
    private let limitBytes: Int64
    private let downloads = Mutex<[String: ProgressiveDownload]>([:])

    public init(client: SubsonicClient, directory: URL, limitBytes: Int64) {
        self.client = client
        self.directory = directory
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Leftovers of downloads cut short when the app last quit.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        where url.pathExtension == "partial" {
            let modified = (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
            if modified.timeIntervalSinceNow < -3600 { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Returns as soon as the song can start: when enough of it has downloaded to be opened.
    public func playableSource(for track: Track) async throws -> PlayableSource {
        if let url = immediateFile(for: track) { return PlayableSource(url: url) }
        if Self.nativeSuffixes.contains(track.suffix) {
            let download = startDownload(track, transcoded: false)
            do {
                try await download.waitUntilPlayable()
                return PlayableSource(url: download.currentURL, growing: download.isComplete ? nil : download)
            } catch PlaybackError.undecodable(_) {
                // Not something this Mac decodes after all: ask the server for MP3 instead.
            }
        }
        // A transcoded stream has no length to judge progress by, so it plays once complete.
        return PlayableSource(url: try await startDownload(track, transcoded: true).waitUntilComplete())
    }

    public func localFile(for track: Track) async throws -> URL {
        if let url = immediateFile(for: track) { return url }
        if Self.nativeSuffixes.contains(track.suffix) {
            do {
                return try await startDownload(track, transcoded: false).waitUntilComplete()
            } catch PlaybackError.undecodable(_) {}
        }
        return try await startDownload(track, transcoded: true).waitUntilComplete()
    }

    public func immediateFile(for track: Track) -> URL? {
        if let url = track.fileURL { return url }
        guard let cached = cachedFile(for: track) else { return nil }
        touch(cached)
        return cached
    }

    public func prepare(_ tracks: [Track]) {
        for track in tracks where track.isServerTrack && cachedFile(for: track) == nil {
            Task.detached(priority: .utility) { _ = try? await self.localFile(for: track) }
        }
    }

    /// The complete cached file for `track`, if it has been fetched before.
    public func cachedFile(for track: Track) -> URL? {
        for url in [rawURL(for: track), transcodedURL(for: track)] where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    public func cacheSize() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    public func clear() {
        for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
    }

    // MARK: -

    private func startDownload(_ track: Track, transcoded: Bool) -> ProgressiveDownload {
        let key = track.id + (transcoded ? "#mp3" : "")
        var created: ProgressiveDownload?
        let download = downloads.withLock { active -> ProgressiveDownload in
            if let existing = active[key], existing.failure == nil { return existing }
            let remote = transcoded
                ? client.streamURL(id: track.id, format: "mp3", maxBitRate: 320)
                : client.streamURL(id: track.id, format: "raw")
            let destination = transcoded ? transcodedURL(for: track) : rawURL(for: track)
            let fresh = ProgressiveDownload(
                title: track.title, from: remote, to: destination,
                playsWhilePartial: !transcoded && Self.progressiveSuffixes.contains(track.suffix)
            ) { [weak self] in
                self?.finished(key)
            }
            active[key] = fresh
            created = fresh
            return fresh
        }
        created?.start()
        return download
    }

    private func finished(_ key: String) {
        downloads.withLock { active in
            if let download = active[key], download.isComplete { active[key] = nil }
        }
        evictIfNeeded()
    }

    private func fileKey(_ track: Track) -> String {
        let safe = track.id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        if safe, track.id.count <= 64 { return track.id }
        return SHA256.hash(data: Data(track.id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func rawURL(for track: Track) -> URL {
        directory.appending(path: "\(fileKey(track)).\(track.suffix.isEmpty ? "audio" : track.suffix)")
    }

    private func transcodedURL(for track: Track) -> URL {
        directory.appending(path: "\(fileKey(track)).transcoded.mp3")
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private struct Entry { let url: URL; let size: Int64; let date: Date }

    /// Complete files only: downloads in progress are never counted or evicted.
    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension != "partial",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return Entry(url: url, size: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Least recently used first, never the newest few — the song playing and the ones queued
    /// behind it.
    private func evictIfNeeded() {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > limitBytes else { return }
        all.sort { $0.date < $1.date }
        for entry in all.dropLast(6) where total > limitBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// One song downloading into the cache, readable while it arrives.
final class ProgressiveDownload: NSObject, URLSessionDataDelegate, GrowingAudioFile, @unchecked Sendable {
    private let title: String
    private let remote: URL
    private let partialURL: URL
    private let finalURL: URL
    private let onFinish: @Sendable () -> Void
    private let playsWhilePartial: Bool

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    private var handle: FileHandle?
    private var errorDocument: Data?
    private var expectedBytes: Int64 = -1
    private var written: Int64 = 0
    /// How much had arrived when the file first opened — an upper bound on its header, cover included.
    private var headerBytes: Int64?
    private var nextOpenAttempt: Int64 = 32_768
    private var lastNotice: (bytes: Int64, time: TimeInterval) = (0, 0)
    private var complete = false
    private var error: Error?
    private var finishedReported = false
    private var observers: [@Sendable () -> Void] = []
    private var playableWaiters: [CheckedContinuation<Void, Error>] = []
    private var completionWaiters: [CheckedContinuation<URL, Error>] = []

    init(title: String, from remote: URL, to finalURL: URL, playsWhilePartial: Bool,
         onFinish: @escaping @Sendable () -> Void) {
        self.title = title
        self.playsWhilePartial = playsWhilePartial
        self.remote = remote
        self.finalURL = finalURL
        self.partialURL = finalURL.appendingPathExtension("partial")
        self.onFinish = onFinish
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.dataTask(with: remote).resume()
    }

    // MARK: GrowingAudioFile

    var currentURL: URL { lock.withLock { complete ? finalURL : partialURL } }
    var isComplete: Bool { lock.withLock { complete } }
    var failure: Error? { lock.withLock { error } }

    func probablyHas(frame: Int64, of length: Int64) -> Bool {
        lock.withLock {
            if complete { return true }
            guard expectedBytes > 0, length > 0, let headerBytes else { return false }
            let audioBytes = Double(max(0, expectedBytes - headerBytes))
            let needed = headerBytes + Int64(audioBytes * Double(min(frame, length)) / Double(length)) + 256_000
            return written >= min(expectedBytes, needed)
        }
    }

    func observe(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(handler) }
    }

    // MARK: Waiting

    func waitUntilPlayable() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let outcome: Result<Void, Error>? = lock.withLock {
                if let error { return .failure(error) }
                if headerBytes != nil { return .success(()) }
                playableWaiters.append(continuation)
                return nil
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    func waitUntilComplete() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let outcome: Result<URL, Error>? = lock.withLock {
                if let error { return .failure(error) }
                if complete { return .success(finalURL) }
                completionWaiters.append(continuation)
                return nil
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            fail(SubsonicError.http((response as? HTTPURLResponse)?.statusCode ?? 0))
            completionHandler(.cancel)
            return
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("json") || type.contains("xml") {
            // Subsonic reports failures as a document sent with HTTP 200.
            lock.withLock { errorDocument = Data() }
            completionHandler(.allow)
            return
        }
        do {
            try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partialURL)
            lock.withLock {
                self.handle = handle
                expectedBytes = response.expectedContentLength
            }
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let handle: FileHandle? = lock.withLock {
            if errorDocument != nil {
                errorDocument?.append(data)
                return nil
            }
            return self.handle
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(error)
            session.invalidateAndCancel()
            return
        }
        var tryOpening = false
        var notify = false
        lock.withLock {
            written += Int64(data.count)
            if playsWhilePartial, headerBytes == nil, written >= nextOpenAttempt {
                tryOpening = true
                // 32 KB, 64 KB… then every megabyte: a cover can precede the audio.
                nextOpenAttempt = min(written * 2, written + 1_048_576)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if written - lastNotice.bytes >= 262_144 || now - lastNotice.time >= 0.25 {
                lastNotice = (written, now)
                notify = true
            }
        }
        if tryOpening, (try? AVAudioFile(forReading: partialURL)) != nil {
            becamePlayable()
        }
        if notify { notifyObservers() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let (handle, document) = lock.withLock { (self.handle, errorDocument) }
        try? handle?.close()
        if let error {
            fail(error)
            return
        }
        if let document {
            fail(SubsonicClient.apiError(in: document) ?? SubsonicError.decoding("expected audio"))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try? FileManager.default.removeItem(at: partialURL)
            } else {
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
            }
        } catch {
            fail(error)
            return
        }
        // Never opened while partial, as formats that wait for the whole file aren't: it must open now.
        if lock.withLock({ headerBytes == nil }), (try? AVAudioFile(forReading: finalURL)) == nil {
            try? FileManager.default.removeItem(at: finalURL)
            fail(PlaybackError.undecodable(title))
            return
        }
        let (playables, completions): ([CheckedContinuation<Void, Error>], [CheckedContinuation<URL, Error>]) = lock.withLock {
            complete = true
            if headerBytes == nil { headerBytes = written }
            defer {
                playableWaiters = []
                completionWaiters = []
            }
            return (playableWaiters, completionWaiters)
        }
        playables.forEach { $0.resume() }
        completions.forEach { $0.resume(returning: finalURL) }
        notifyObservers()
        reportFinished()
    }

    // MARK: -

    private func becamePlayable() {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            guard headerBytes == nil else { return [] }
            headerBytes = written
            defer { playableWaiters = [] }
            return playableWaiters
        }
        waiters.forEach { $0.resume() }
    }

    private func fail(_ failure: Error) {
        let pending: ([CheckedContinuation<Void, Error>], [CheckedContinuation<URL, Error>], FileHandle?)? = lock.withLock {
            guard error == nil, !complete else { return nil }
            error = failure
            defer {
                playableWaiters = []
                completionWaiters = []
            }
            return (playableWaiters, completionWaiters, handle)
        }
        guard let (playables, completions, handle) = pending else { return }
        try? handle?.close()
        try? FileManager.default.removeItem(at: partialURL)
        playables.forEach { $0.resume(throwing: failure) }
        completions.forEach { $0.resume(throwing: failure) }
        notifyObservers()
        reportFinished()
    }

    private func notifyObservers() {
        let handlers = lock.withLock { observers }
        handlers.forEach { $0() }
    }

    private func reportFinished() {
        let first = lock.withLock { () -> Bool in
            defer { finishedReported = true }
            return !finishedReported
        }
        if first { onFinish() }
    }
}
