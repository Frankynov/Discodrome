import AVFoundation
import Foundation
import Testing
@testable import DiscodromeCore

let AVFormatIDKeyName = AVFormatIDKey
let kAudioFormatLinearPCMValue = Int(kAudioFormatLinearPCM)

/// Which queue entries the player reported as current, in order.
final class IndexLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int?] = []

    func record(_ index: Int?) {
        lock.withLock { if values.last != index { values.append(index) } }
    }

    var recorded: [Int?] { lock.withLock { values } }
}

@Suite(.serialized)
struct GaplessTests {
    static let rate = 44_100.0

    /// Frames `offset..<offset+frames` of one continuous stereo sine (cosine on the right), so
    /// consecutive files join into a seamless wave and any gap or overlap shows as a jump.
    static func sample(_ n: Int, channel: Int) -> Float {
        let phase = 2 * Double.pi * 441 * Double(n) / rate
        return Float(0.5 * (channel == 0 ? sin(phase) : cos(phase)))
    }

    static func writeTone(to url: URL, frames: Int, offset: Int, rate: Double, settings extra: [String: Any]) throws {
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        settings.merge(extra) { $1 }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = sample(offset + i, channel: 0)
            buffer.floatChannelData![1][i] = sample(offset + i, channel: 1)
        }
        try file.write(from: buffer)
    }

    static func makeTracks(_ lengths: [Int], suffix: String, settings: [String: Any]) throws -> [Track] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "discodrome-gapless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var offset = 0
        var tracks: [Track] = []
        for (index, length) in lengths.enumerated() {
            let url = directory.appending(path: "part\(index).\(suffix)")
            try writeTone(to: url, frames: length, offset: offset, rate: rate, settings: settings)
            offset += length
            tracks.append(Track(id: "t\(index)", origin: .file(url), title: "Part \(index)", artist: "Test", albumArtist: "Test",
                                album: "Gapless", trackNumber: index + 1, duration: Double(length) / rate, suffix: suffix))
        }
        return tracks
    }

    /// Plays `tracks` into memory and returns both channels of everything rendered. `step` runs
    /// before every render, to let a test change the world as playback advances.
    static func render(_ tracks: [Track], frames total: Int, observed: IndexLog? = nil,
                       provider: AudioFileProvider = LocalFileProvider(), step: () -> Void = {}) async throws -> [[Float]] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let player = GaplessPlayer(provider: provider, offlineFormat: format) { state in
            observed?.record(state.currentIndex)
        }
        player.play(tracks.map { PlayerItem($0) }, startAt: 0)
        var output: [[Float]] = [[], []]
        var idle = 0
        while output[0].count < total, idle < 2_000 {
            step()
            player.sync()
            guard let buffer = try player.renderOffline(frames: 2048) else {
                idle += 1
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            for channel in 0..<2 {
                output[channel] += UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
            }
        }
        return output
    }

    static func largestDeviation(_ output: [[Float]], frames: Int) -> (error: Float, frame: Int) {
        var worst: (Float, Int) = (0, -1)
        for i in 0..<min(frames, output[0].count) {
            for channel in 0..<2 {
                let error = abs(output[channel][i] - sample(i, channel: channel))
                if error > worst.0 { worst = (error, i) }
            }
        }
        return worst
    }

    @Test func flacTracksJoinSampleExactly() async throws {
        let lengths = [30_000, 41_234, 33_333]
        let tracks = try Self.makeTracks(lengths, suffix: "flac", settings: [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: 24])
        let total = lengths.reduce(0, +)
        let log = IndexLog()
        let output = try await Self.render(tracks, frames: total + 8_192, observed: log)

        #expect(output[0].count >= total)
        let (error, frame) = Self.largestDeviation(output, frames: total)
        #expect(error < 1e-4, "output departs from the continuous wave by \(error) at frame \(frame)")
        let tail = output[0].dropFirst(total + 4_096).prefix(2_048)
        #expect(tail.allSatisfy { $0 == 0 }, "silence once the queue has ended")
        #expect(log.recorded.compactMap { $0 } == [0, 1, 2])
    }

    @Test func aacTracksJoinWithoutPrimingGaps() async throws {
        // AAC is lossy, so compare loosely — but a priming gap or padding (≈2112 frames of
        // near-silence, or a 20ms jump) would blow far past this tolerance.
        let lengths = [44_100, 44_100]
        let tracks = try Self.makeTracks(lengths, suffix: "m4a", settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 256_000])
        let total = lengths.reduce(0, +)
        let output = try await Self.render(tracks, frames: total)
        // Skip the codec's own settling at the very start and end of the stream.
        var worst: Float = 0
        for i in 4_096..<(total - 4_096) {
            worst = max(worst, abs(output[0][i] - Self.sample(i, channel: 0)))
        }
        #expect(worst < 0.05, "AAC seam deviates by \(worst)")
    }
}

/// A file that "downloads" in the pieces a test hands it, the way ProgressiveDownload writes one.
final class GrowingTestFile: GrowingAudioFile, @unchecked Sendable {
    private let bytes: Data
    var totalBytes: Int { bytes.count }
    private let partialURL: URL
    private let finalURL: URL
    let frames: Int
    private let lock = NSLock()
    private var written = 0
    private var headerBytes: Int?
    private var complete = false
    private var observers: [@Sendable () -> Void] = []

    init(source: URL, frames: Int, initialFraction: Double) throws {
        bytes = try Data(contentsOf: source)
        self.frames = frames
        finalURL = source.deletingPathExtension().appendingPathExtension("downloaded.flac")
        partialURL = finalURL.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        grow(by: Int(Double(bytes.count) * initialFraction))
    }

    var currentURL: URL { lock.withLock { complete ? finalURL : partialURL } }
    var isComplete: Bool { lock.withLock { complete } }
    var failure: Error? { nil }

    func probablyHas(frame: Int64, of length: Int64) -> Bool {
        lock.withLock {
            if complete { return true }
            guard let headerBytes, length > 0 else { return false }
            let needed = headerBytes + Int(Double(bytes.count - headerBytes) * Double(frame) / Double(length)) + 4_096
            return written >= min(bytes.count, needed)
        }
    }

    func observe(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(handler) }
    }

    /// Appends the next `count` bytes, renaming the file into place once all have arrived.
    func grow(by count: Int) {
        let (chunk, finished) = lock.withLock { () -> (Data, Bool) in
            guard !complete else { return (Data(), false) }
            let end = min(bytes.count, written + max(1, count))
            defer { written = end }
            return (bytes.subdata(in: written..<end), end == bytes.count)
        }
        guard !chunk.isEmpty else { return }
        let handle = try! FileHandle(forWritingTo: partialURL)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: chunk)
        try! handle.close()
        if lock.withLock({ headerBytes == nil }), (try? AVAudioFile(forReading: partialURL)) != nil {
            lock.withLock { headerBytes = written }
        }
        if finished {
            try! FileManager.default.moveItem(at: partialURL, to: finalURL)
            lock.withLock { complete = true }
        }
        lock.withLock { observers }.forEach { $0() }
    }
}

struct GrowingTestProvider: AudioFileProvider {
    let files: [String: GrowingTestFile]

    func localFile(for track: Track) async throws -> URL { files[track.id]!.currentURL }
    func immediateFile(for track: Track) -> URL? { nil }
    func playableSource(for track: Track) async throws -> PlayableSource {
        PlayableSource(url: files[track.id]!.currentURL, growing: files[track.id]!)
    }
}

extension GaplessTests {
    @Test func songsStillDownloadingPlayWithoutAGap() async throws {
        let lengths = [120_000, 90_000, 60_000]
        let tracks = try Self.makeTracks(lengths, suffix: "flac", settings: [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: 24])
        var files: [String: GrowingTestFile] = [:]
        for (track, length) in zip(tracks, lengths) {
            files[track.id] = try GrowingTestFile(source: track.fileURL!, frames: length, initialFraction: 0.3)
        }
        let ordered = tracks.map { files[$0.id]! }
        let total = lengths.reduce(0, +)
        let log = IndexLog()

        // One download at a time, arriving at twice the speed of playback — so the engine keeps
        // reaching the end of what has downloaded and must reopen the file to carry on.
        let output = try await Self.render(tracks, frames: total, observed: log, provider: GrowingTestProvider(files: files)) {
            guard let file = ordered.first(where: { !$0.isComplete }) else { return }
            // Each render plays 2,048 frames; 4,096 frames' worth of file arrives.
            file.grow(by: Int(Double(file.totalBytes) / Double(file.frames) * 4_096))
        }

        #expect(output[0].count >= total)
        let (error, frame) = Self.largestDeviation(output, frames: total)
        #expect(error < 1e-4, "output departs from the continuous wave by \(error) at frame \(frame)")
        #expect(log.recorded.compactMap { $0 } == [0, 1, 2])
        let everythingDownloaded = ordered.allSatisfy { $0.isComplete }
        #expect(everythingDownloaded)
    }
}
