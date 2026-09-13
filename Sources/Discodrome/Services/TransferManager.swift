import DiscodromeCore
import Foundation
import Observation

enum TransferError: LocalizedError {
    case offline
    case alreadyExists(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .offline: return "The server isn't reachable."
        case .alreadyExists(let name): return "“\(name)” already exists on the device."
        case .disconnected: return "The device was disconnected."
        }
    }
}

/// Copies server songs onto a device: download (or reuse the playback cache), write through a
/// temporary file, add synced lyrics, record the copy so it's recognised next time.
@MainActor @Observable
final class TransferManager {
    struct Job: Identifiable, Sendable {
        enum Phase: Equatable, Sendable {
            case waiting, downloading(Double), writing(Double), done, failed(String)
        }

        let id = UUID()
        /// The copy this song was part of — one drag or one button press.
        var batchID = UUID()
        let track: Track
        let deviceID: String
        let relativePath: String
        let transcode: Bool
        let estimatedBytes: Int64
        var phase: Phase = .waiting

        var isFinished: Bool {
            switch phase {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    struct Batch: Identifiable, Sendable {
        let id: UUID
        let deviceID: String
        let title: String
        let started: Date
    }

    struct Plan {
        var jobs: [Job]
        var alreadyOnDevice: Int
        var notFromServer: Int
        var bytes: Int64
        var device: Device

        var fits: Bool { bytes + TransferManager.overhead(songs: jobs.count, blockSize: device.blockSize) <= device.available }
    }

    /// Songs take more room than their size: the last cluster of each file is only partly used,
    /// and a lyrics file — however small — takes a whole cluster (256 KB on a large exFAT card).
    nonisolated static func overhead(songs: Int, blockSize: Int64) -> Int64 {
        Int64(songs) * 2 * blockSize + (16 << 20)
    }

    /// Everything the SNOWSKY DISC plays; other formats get transcoded to MP3 by the server.
    static let deviceSuffixes: Set<String> = [
        "flac", "wav", "aif", "aiff", "aifc", "m4a", "mp4", "alac", "aac", "ape", "wma", "mp3", "ogg", "oga", "dsf", "dff",
    ]

    private(set) var jobs: [Job] = []
    /// Every copy started this session, oldest first.
    private(set) var batches: [Batch] = []
    private(set) var summary: String?
    var planNeedingConfirmation: Plan?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let devices: DeviceManager
    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private let downloader = Downloader()
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Index of the first batch the running worker picked up, for its summary.
    @ObservationIgnored private var runStartBatch = 0

    init(settings: AppSettings, library: LibraryStore, devices: DeviceManager, player: PlayerController) {
        self.settings = settings
        self.library = library
        self.devices = devices
        self.player = player
    }

    var isActive: Bool { jobs.contains { !$0.isFinished } }

    func isActive(on deviceID: String) -> Bool {
        jobs.contains { $0.deviceID == deviceID && !$0.isFinished }
    }

    var activeJob: Job? {
        jobs.first { job in
            switch job.phase {
            case .downloading, .writing: return true
            default: return false
            }
        }
    }

    /// Bytes still to be written in the current batch — the capacity bar shows them as pending.
    func pendingBytes(on deviceID: String) -> Int64 {
        jobs.reduce(0) { total, job in
            guard job.deviceID == deviceID else { return total }
            switch job.phase {
            case .waiting, .downloading: return total + job.estimatedBytes
            case .writing(let fraction): return total + Int64(Double(job.estimatedBytes) * (1 - fraction))
            default: return total
            }
        }
    }

    /// Songs of the copies still under way — what progress and the status line describe.
    private var currentJobs: [Job] {
        let running = Set(jobs.filter { !$0.isFinished }.map(\.batchID))
        return jobs.filter { running.contains($0.batchID) }
    }

    var progress: (done: Int, total: Int, fraction: Double) {
        let batch = currentJobs
        let total = batch.count
        let done = batch.filter(\.isFinished).count
        let bytes = batch.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        let written = batch.reduce(0.0) { sum, job in
            switch job.phase {
            case .done, .failed: return sum + Double(job.estimatedBytes)
            case .writing(let fraction): return sum + Double(job.estimatedBytes) * (0.1 + 0.9 * fraction)
            case .downloading(let fraction): return sum + Double(job.estimatedBytes) * 0.1 * fraction
            case .waiting: return sum
            }
        }
        return (done, total, bytes > 0 ? written / Double(bytes) : 0)
    }

    // MARK: Planning

    func plan(_ tracks: [Track], to device: Device) -> Plan {
        var seen = Set<String>()
        var planned: [Job] = []
        var alreadyThere = 0
        var notFromServer = 0
        var bytes: Int64 = 0
        let queuedIDs = Set(jobs.filter { $0.deviceID == device.id && $0.phase != .failed("") && !$0.isFinished }.map(\.track.id))
        // FAT and exFAT are case-insensitive.
        var taken = Set((devices.contents[device.id]?.files ?? []).map { $0.relativePath.lowercased() })
        taken.formUnion(jobs.filter { $0.deviceID == device.id && !$0.isFinished }.map { $0.relativePath.lowercased() })
        let builder = settings.pathBuilder

        for track in tracks where seen.insert(track.id).inserted {
            guard track.isServerTrack else { notFromServer += 1; continue }
            if devices.presence(of: track.id, on: device.id) != nil || queuedIDs.contains(track.id) {
                alreadyThere += 1
                continue
            }
            let transcode = !Self.deviceSuffixes.contains(track.suffix)
            let suffix = transcode ? "mp3" : track.suffix
            let discCount = track.albumID.flatMap { library.tracksByAlbum[$0] }?.compactMap(\.discNumber).max()
            let path = Self.uniquePath(builder.relativePath(for: track, suffix: suffix, discCount: discCount), taken: &taken, root: device.url)
            let estimate = transcode
                ? Int64(track.duration * 40_000)
                : (track.size ?? Int64(track.duration * Double(track.bitRate ?? 320) * 125))
            bytes += estimate
            planned.append(Job(track: track, deviceID: device.id, relativePath: path, transcode: transcode, estimatedBytes: estimate))
        }
        return Plan(jobs: planned, alreadyOnDevice: alreadyThere, notFromServer: notFromServer, bytes: bytes, device: device)
    }

    private static func uniquePath(_ path: String, taken: inout Set<String>, root: URL) -> String {
        var candidate = path
        var counter = 2
        let ext = (path as NSString).pathExtension
        let stem = (path as NSString).deletingPathExtension
        while taken.contains(candidate.lowercased()) || FileManager.default.fileExists(atPath: root.appending(path: candidate).path) {
            candidate = "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// Plans and starts a copy, or holds it for confirmation when it won't fit.
    func copy(_ tracks: [Track], to device: Device) {
        let plan = plan(tracks, to: device)
        guard !plan.jobs.isEmpty else {
            summary = plan.alreadyOnDevice > 0
                ? "\(plan.alreadyOnDevice == 1 ? "That song is" : "All \(plan.alreadyOnDevice) songs are") already on \(device.name)."
                : "Nothing to copy — only songs from the server can be copied."
            return
        }
        if plan.fits { start(plan) } else { planNeedingConfirmation = plan }
    }

    /// Starts the jobs that fit, in order, when the whole plan doesn't.
    func startFittingPart(of plan: Plan) {
        let blockSize = plan.device.blockSize
        var budget = plan.device.available - Self.overhead(songs: 0, blockSize: blockSize)
        var fitting = plan
        fitting.jobs = plan.jobs.filter { job in
            let needed = job.estimatedBytes + Self.overhead(songs: 1, blockSize: blockSize) - Self.overhead(songs: 0, blockSize: blockSize)
            guard needed <= budget else { return false }
            budget -= needed
            return true
        }
        fitting.bytes = fitting.jobs.reduce(0) { $0 + $1.estimatedBytes }
        if !fitting.jobs.isEmpty { start(fitting) }
    }

    func start(_ plan: Plan) {
        let batch = Batch(id: UUID(), deviceID: plan.device.id, title: Self.title(for: plan.jobs.map(\.track)), started: Date())
        batches.append(batch)
        jobs += plan.jobs.map { job in
            var job = job
            job.batchID = batch.id
            return job
        }
        let skipped = plan.alreadyOnDevice
        summary = skipped > 0 ? "\(skipped) song\(skipped == 1 ? " was" : "s were") already on \(plan.device.name)." : nil
        if worker == nil {
            runStartBatch = batches.count - 1
            worker = Task { await run() }
        }
    }

    /// "It Goes On — Westside Cowboy", "5 songs by Glass Rivers", "12 songs".
    static func title(for tracks: [Track]) -> String {
        guard let first = tracks.first else { return "Songs" }
        if Set(tracks.map { $0.album + "\u{1}" + $0.albumArtist }).count == 1 {
            return "\(first.album) — \(first.albumArtist)"
        }
        if Set(tracks.map(\.albumArtist)).count == 1 {
            return "\(tracks.count) songs by \(first.albumArtist)"
        }
        return "\(tracks.count) songs"
    }

    func cancelAll() {
        worker?.cancel()
        for index in jobs.indices where !jobs[index].isFinished {
            jobs[index].phase = .failed("Cancelled")
        }
    }

    /// Removes the copies that have finished; ones still under way stay.
    func clearFinished() {
        let unfinished = Set(jobs.filter { !$0.isFinished }.map(\.batchID))
        jobs.removeAll { !unfinished.contains($0.batchID) }
        batches.removeAll { !unfinished.contains($0.id) }
        summary = nil
    }

    // MARK: Running

    private struct SourceFile: Sendable {
        let url: URL
        let isTemporary: Bool
    }

    private func setPhase(_ id: UUID, _ phase: Job.Phase) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].phase = phase
    }

    private func run() async {
        var prefetch: (id: UUID, task: Task<SourceFile, Error>)?
        defer {
            prefetch?.task.cancel()
            worker = nil
            finishBatch()
        }
        while !Task.isCancelled, let job = jobs.first(where: { $0.phase == .waiting }) {
            guard let device = devices.devices.first(where: { $0.id == job.deviceID }) else {
                setPhase(job.id, .failed(TransferError.disconnected.localizedDescription))
                continue
            }
            let sourceTask = prefetch?.id == job.id ? prefetch!.task : fetchSource(job)
            setPhase(job.id, .downloading(0))
            // Fetch the next song while this one is written: the card is the slow part.
            if let next = jobs.first(where: { $0.phase == .waiting }) {
                prefetch = (next.id, fetchSource(next))
            } else {
                prefetch = nil
            }
            do {
                let source = try await sourceTask.value
                defer { if source.isTemporary { try? FileManager.default.removeItem(at: source.url) } }
                setPhase(job.id, .writing(0))
                let destination = device.url.appending(path: job.relativePath)
                let jobID = job.id
                let written = try await Self.write(source.url, to: destination, root: device.url) { fraction in
                    Task { @MainActor in self.setPhase(jobID, .writing(fraction)) }
                }
                await writeLyrics(for: job.track, beside: destination, root: device.url)
                await record(job, destination: destination, size: written)
                setPhase(job.id, .done)
            } catch is CancellationError {
                setPhase(job.id, .failed("Cancelled"))
            } catch let error as URLError where error.code == .cancelled {
                setPhase(job.id, .failed("Cancelled"))
            } catch {
                setPhase(job.id, .failed(error.localizedDescription))
            }
        }
    }

    private func finishBatch() {
        let runBatches = Set(batches.dropFirst(runStartBatch).map(\.id))
        let runJobs = jobs.filter { runBatches.contains($0.batchID) }
        let copied = runJobs.filter { $0.phase == .done }
        let failed = runJobs.filter { if case .failed(let reason) = $0.phase { return reason != "Cancelled" } else { return false } }
        guard !runJobs.isEmpty else { return }
        let deviceName = devices.devices.first { $0.id == runJobs.first?.deviceID }?.name ?? "the device"
        var parts: [String] = []
        if !copied.isEmpty { parts.append("Copied \(copied.count) song\(copied.count == 1 ? "" : "s") to \(deviceName).") }
        if !failed.isEmpty { parts.append("\(failed.count) couldn't be copied.") }
        if let summary, copied.isEmpty == false { parts.append(summary) }
        summary = parts.isEmpty ? nil : parts.joined(separator: " ")
        for id in Set(runJobs.map(\.deviceID)) { devices.rematch(id) }
    }

    private func fetchSource(_ job: Job) -> Task<SourceFile, Error> {
        let cached = job.transcode ? nil : player.provider.serverProvider?.cachedFile(for: job.track)
        let client = library.client
        let downloader = downloader
        let jobID = job.id
        return Task {
            if let cached, cached.pathExtension.lowercased() == job.track.suffix {
                return SourceFile(url: cached, isTemporary: false)
            }
            guard let client else { throw TransferError.offline }
            let url = job.transcode
                ? client.streamURL(id: job.track.id, format: "mp3", maxBitRate: 320)
                : client.streamURL(id: job.track.id, format: "raw")
            let file = try await downloader.download(url) { fraction in
                Task { @MainActor in
                    guard let index = self.jobs.firstIndex(where: { $0.id == jobID }),
                          case .downloading = self.jobs[index].phase else { return }
                    self.jobs[index].phase = .downloading(fraction)
                }
            }
            return SourceFile(url: file, isTemporary: true)
        }
    }

    /// Plain data copy through a hidden temporary name, then a rename. Copying data only (no
    /// extended attributes) is what keeps macOS from littering the card with `._` files.
    private nonisolated static func write(_ source: URL, to destination: URL, root: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        let task = Task.detached(priority: .userInitiated) { () throws -> Int64 in
            let fileManager = FileManager.default
            let folder = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw TransferError.alreadyExists(destination.lastPathComponent)
            }
            let partial = folder.appending(path: ".discodrome-\(UUID().uuidString).part")
            guard fileManager.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            do {
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: partial)
                let total = Double(max(1, (try? fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)??.int64Value ?? 1))
                var written: Int64 = 0
                var reported = 0.0
                while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    let fraction = Double(written) / total
                    if fraction - reported >= 0.02 {
                        reported = fraction
                        progress(min(1, fraction))
                    }
                }
                // On disk before we call it done, so pulling the cable afterwards is safe.
                try output.synchronize()
                try output.close()
                try fileManager.moveItem(at: partial, to: destination)
                // The attributes macOS attached would otherwise sit on the card as "._" files.
                AppleDouble.removeTwins(of: destination, upTo: root)
                return written
            } catch {
                try? fileManager.removeItem(at: partial)
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func writeLyrics(for track: Track, beside destination: URL, root: URL) async {
        guard settings.writeLyricsFiles, let client = library.client else { return }
        let structured = library.supportsStructuredLyrics
        guard let lyrics = try? await client.lyrics(for: track, structured: structured),
              let text = lyrics.lrcText(title: track.title, artist: track.artist, album: track.album) else { return }
        let url = destination.deletingPathExtension().appendingPathExtension("lrc")
        await Task.detached(priority: .utility) {
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try? Data(text.utf8).write(to: url)
            AppleDouble.removeTwins(of: url, upTo: root)
        }.value
    }

    private func record(_ job: Job, destination: URL, size: Int64) async {
        let track = job.track
        let (info, modified) = await Task.detached(priority: .utility) { () -> (AudioFileInfo, Date) in
            var info = AudioTagReader.read(destination) ?? AudioFileInfo()
            info.title = info.title ?? track.title
            info.artist = info.artist ?? track.artist
            info.albumArtist = info.albumArtist ?? track.albumArtist
            info.album = info.album ?? track.album
            info.trackNumber = info.trackNumber ?? track.trackNumber
            info.discNumber = info.discNumber ?? track.discNumber
            info.duration = info.duration ?? track.duration
            let modified = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return (info, modified)
        }.value
        let file = DeviceFile(relativePath: job.relativePath, size: size, modified: modified, info: info, sourceTrackID: track.id)
        devices.recordCopy(file, of: track, on: job.deviceID)
    }
}

/// URLSession downloads with progress, bridged to async/await.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Handler {
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<URL, Error>
    }

    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { handlers[task.taskIdentifier] = Handler(progress: progress, continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let handler = lock.withLock { handlers[downloadTask.taskIdentifier] }
        handler?.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let handler = lock.withLock({ handlers.removeValue(forKey: downloadTask.taskIdentifier) }) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            return handler.continuation.resume(throwing: SubsonicError.http(status))
        }
        let type = response?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("json") || type.contains("xml") {
            let data = (try? Data(contentsOf: location)) ?? Data()
            return handler.continuation.resume(throwing: SubsonicClient.apiError(in: data) ?? SubsonicError.decoding("expected audio"))
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "discodrome-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            handler.continuation.resume(returning: destination)
        } catch {
            handler.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let handler = lock.withLock({ handlers.removeValue(forKey: task.taskIdentifier) }) else { return }
        handler.continuation.resume(throwing: error)
    }
}
