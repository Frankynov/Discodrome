import AVFoundation
import Foundation

/// Supplies local audio files for tracks — downloading server tracks into a cache, or handing
/// back the path of a file on a device.
public protocol AudioFileProvider: Sendable {
    func localFile(for track: Track) async throws -> URL
    /// The file, when it's at hand without waiting — lets cached tracks start instantly.
    func immediateFile(for track: Track) -> URL?
    /// Where to read the track from as soon as it can start — possibly a file still downloading.
    func playableSource(for track: Track) async throws -> PlayableSource
    /// Start fetching tracks that will be needed soon.
    func prepare(_ tracks: [Track])
}

extension AudioFileProvider {
    public func immediateFile(for track: Track) -> URL? { track.fileURL }
    public func playableSource(for track: Track) async throws -> PlayableSource {
        PlayableSource(url: try await localFile(for: track))
    }
    public func prepare(_ tracks: [Track]) {}
}

public struct LocalFileProvider: AudioFileProvider {
    public init() {}
    public func localFile(for track: Track) async throws -> URL {
        guard let url = track.fileURL else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
}

/// One entry in the play queue. The same track can appear twice, so entries have their own id.
public struct PlayerItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let track: Track

    public init(_ track: Track, id: UUID = UUID()) {
        self.track = track
        self.id = id
    }
}

public enum RepeatMode: String, Sendable, Codable, CaseIterable {
    case off, all, one
}

public struct PlaybackState: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case stopped, loading, playing, paused }

    public var status: Status = .stopped
    public var items: [PlayerItem] = []
    public var currentIndex: Int?
    /// Seconds into the current track at `measuredAt`.
    public var position: TimeInterval = 0
    /// `ProcessInfo.systemUptime` when `position` was measured.
    public var measuredAt: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var repeatMode: RepeatMode = .off
    public var lastError: String?
    /// Times the audio ran out before the queue did — each one an audible gap, such as a download
    /// falling behind.
    public var underruns = 0

    public init() {}

    public var currentItem: PlayerItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    /// The position now, extrapolated while playing — lets views animate without the engine
    /// publishing a stream of updates.
    public func position(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        guard status == .playing else { return position }
        let extrapolated = position + max(0, uptime - measuredAt)
        return duration > 0 ? min(duration, extrapolated) : extrapolated
    }
}

/// Sample-accurate gapless playback on AVAudioEngine.
///
/// Files are decoded in half-second chunks and scheduled back to back on one player node, so
/// the last sample of a track is followed directly by the first sample of the next. Codec
/// priming and padding (AAC, MP3 with a LAME header) are already trimmed by `AVAudioFile`.
/// When the next track has a different sample rate or channel count, the node plays out, is
/// reconnected with the new format, and carries on — the only case with a (tiny) gap, and the
/// mixer resamples to the output device, so nothing else needs converting.
///
/// A song can play while it downloads. Decoding stops exactly at the edge of what has arrived;
/// when more comes in the file is reopened — an open file doesn't see later bytes — and reading
/// carries on from the same frame, so the output is the same, sample for sample.
public final class GaplessPlayer: @unchecked Sendable {
    public typealias Observer = @Sendable (PlaybackState) -> Void

    static let aheadSeconds = 2.5
    static let chunkSeconds = 0.5
    /// How much of a downloading song must have arrived beyond the start point before it plays.
    static let prebufferSeconds = 1.0

    private let work = DispatchQueue(label: "Discodrome.GaplessPlayer", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let provider: AudioFileProvider
    private let observer: Observer
    private let isOffline: Bool

    // Everything below is confined to `work`.
    private var state = PlaybackState()
    private var wantsToPlay = false
    private var files: [UUID: AVAudioFile] = [:]
    private var resolving: Set<UUID> = []
    private var failures: [UUID: String] = [:]
    /// Entries whose file is still downloading.
    private var growing: [UUID: GrowingAudioFile] = [:]
    /// Entries that reached the end of what has downloaded, and the frame to carry on from.
    private var stalled: [UUID: AVAudioFramePosition] = [:]

    private struct Segment {
        let itemID: UUID
        /// Node sample time at which this item's audio begins.
        let startSample: AVAudioFramePosition
        /// Frame within the file that plays at `startSample`.
        let startFrame: AVAudioFramePosition
    }

    private var segments: [Segment] = []
    private var scheduledFrames: AVAudioFramePosition = 0
    private var readingID: UUID?
    private var pendingStart: (itemID: UUID, seconds: TimeInterval)?
    private var connectionFormat: AVAudioFormat?
    private var generation = 0
    private var reachedEnd = false
    private var lastSampleTime: AVAudioFramePosition = 0
    private var gain: Float = 1
    private var timer: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?

    /// - Parameter offlineFormat: renders into memory instead of the speakers (tests).
    public init(provider: AudioFileProvider, offlineFormat: AVAudioFormat? = nil, observer: @escaping Observer) {
        self.provider = provider
        self.observer = observer
        self.isOffline = offlineFormat != nil
        engine.attach(node)
        if let offlineFormat {
            try? engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 8192)
        } else {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.work.async { self.handleConfigurationChange() }
            }
        }
    }

    deinit {
        timer?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
    }

    // MARK: - Commands

    public func play(_ items: [PlayerItem], startAt index: Int) {
        work.async { [self] in
            state.items = items
            files.removeAll()
            failures.removeAll()
            growing.removeAll()
            stalled.removeAll()
            guard items.indices.contains(index) else { return finishQueue() }
            startItem(items[index].id, at: 0, play: true)
        }
    }

    public func jump(to index: Int) {
        work.async { [self] in
            guard state.items.indices.contains(index) else { return }
            failures[state.items[index].id] = nil
            startItem(state.items[index].id, at: 0, play: true)
        }
    }

    public func togglePlayPause() {
        work.async { [self] in
            if wantsToPlay { pauseNow() } else { playNow() }
        }
    }

    public func play() { work.async { [self] in playNow() } }
    public func pause() { work.async { [self] in pauseNow() } }

    public func stop() {
        work.async { [self] in finishQueue() }
    }

    public func next() {
        work.async { [self] in
            guard let index = state.currentIndex else { return }
            if let next = nextPlayableIndex(after: index, automatic: false) {
                startItem(state.items[next].id, at: 0, play: wantsToPlay)
            } else {
                finishQueue()
            }
        }
    }

    public func previous() {
        work.async { [self] in
            guard let index = state.currentIndex else { return }
            if currentPosition() > 3 || (index == 0 && state.repeatMode != .all) {
                startItem(state.items[index].id, at: 0, play: wantsToPlay)
            } else {
                let previous = index > 0 ? index - 1 : state.items.count - 1
                startItem(state.items[previous].id, at: 0, play: wantsToPlay)
            }
        }
    }

    public func seek(to seconds: TimeInterval) {
        work.async { [self] in
            guard let item = state.currentItem else { return }
            let upper = state.duration > 0 ? state.duration - 0.05 : seconds
            startItem(item.id, at: max(0, min(seconds, upper)), play: wantsToPlay)
        }
    }

    /// Linear gain, 0...1.
    public func setVolume(_ volume: Float) {
        work.async { [self] in
            gain = max(0, min(1, volume))
            engine.mainMixerNode.outputVolume = gain
        }
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        work.async { [self] in
            guard state.repeatMode != mode else { return }
            state.repeatMode = mode
            reconsiderUpcoming()
        }
    }

    /// Replaces the queue while keeping the current entry playing — for Play Next, Add to Up
    /// Next, reordering and shuffle.
    public func updateQueue(_ items: [PlayerItem]) {
        work.async { [self] in
            let currentID = state.currentItem?.id
            state.items = items
            guard let currentID else { return publish() }
            guard let index = index(of: currentID) else {
                if let first = items.first { startItem(first.id, at: 0, play: wantsToPlay) } else { finishQueue() }
                return
            }
            state.currentIndex = index
            reconsiderUpcoming()
        }
    }

    // MARK: - Tests

    /// Renders `frames` in offline mode after topping up the schedule.
    public func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        try work.sync {
            pump()
            guard isOffline, engine.isRunning,
                  let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else { return nil }
            _ = try engine.renderOffline(frames, to: buffer)
            return buffer
        }
    }

    /// Blocks until queued commands have run.
    public func sync() { work.sync {} }

    // MARK: - Transport internals

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func index(of id: UUID) -> Int? {
        state.items.firstIndex { $0.id == id }
    }

    private func startItem(_ id: UUID, at seconds: TimeInterval, play: Bool) {
        generation += 1
        node.stop()
        segments = []
        scheduledFrames = 0
        readingID = nil
        reachedEnd = false
        lastSampleTime = 0
        wantsToPlay = play
        pendingStart = (id, seconds)
        failures[id] = nil
        state.currentIndex = index(of: id)
        state.position = seconds
        state.measuredAt = now
        if let file = files[id] {
            state.duration = Double(file.length) / file.processingFormat.sampleRate
        } else if let track = state.currentItem?.track {
            state.duration = track.duration
        }
        state.status = play ? .loading : .paused
        publish()
        pump()
    }

    private func playNow() {
        switch state.status {
        case .playing:
            return
        case .loading:
            wantsToPlay = true
        case .paused:
            guard let item = state.currentItem else { return }
            if pendingStart != nil {
                wantsToPlay = true
                state.status = .loading
                publish()
                pump()
            } else {
                // Resume by rescheduling from where playback was heard to stop: robust
                // against engine and device changes made while paused.
                startItem(item.id, at: state.position, play: true)
            }
        case .stopped:
            if let item = state.currentItem ?? state.items.first {
                startItem(item.id, at: 0, play: true)
            }
        }
    }

    private func pauseNow() {
        wantsToPlay = false
        switch state.status {
        case .playing:
            state.position = currentPosition()
            state.measuredAt = now
            generation += 1
            node.stop()
            segments = []
            scheduledFrames = 0
            readingID = nil
            reachedEnd = false
            if !isOffline { engine.pause() }
            stopTimer()
            state.status = .paused
        case .loading:
            state.status = .paused
        default:
            return
        }
        publish()
    }

    private func finishQueue() {
        generation += 1
        node.stop()
        stopTimer()
        segments = []
        scheduledFrames = 0
        readingID = nil
        pendingStart = nil
        reachedEnd = false
        wantsToPlay = false
        state.status = .stopped
        state.currentIndex = nil
        state.position = 0
        state.duration = 0
        if !isOffline { engine.pause() }
        publish()
    }

    /// After the queue or repeat mode changed: if audio from an entry that's no longer next
    /// is already scheduled, reschedule from the current position.
    private func reconsiderUpcoming() {
        guard let current = state.currentItem else { return publish() }
        reachedEnd = false
        if let readingID, readingID != current.id || state.repeatMode == .one {
            let expected = state.currentIndex.flatMap { nextPlayableIndex(after: $0, automatic: true) }.map { state.items[$0].id }
            let crossedIntoNext = segments.contains { $0.itemID != current.id } || readingID != current.id
            if crossedIntoNext && expected != readingID {
                return startItem(current.id, at: currentPosition(), play: wantsToPlay)
            }
        }
        publish()
        prepareUpcoming()
        pump()
    }

    private func nextPlayableIndex(after index: Int, automatic: Bool) -> Int? {
        let count = state.items.count
        guard count > 0 else { return nil }
        if automatic && state.repeatMode == .one { return failures[state.items[index].id] == nil ? index : nil }
        var candidate = index
        for _ in 0..<count {
            candidate += 1
            if candidate >= count {
                guard state.repeatMode == .all else { return nil }
                candidate = 0
            }
            if failures[state.items[candidate].id] == nil { return candidate }
        }
        return nil
    }

    // MARK: - Scheduling

    private func pump() {
        if let pending = pendingStart {
            beginPending(pending)
            return
        }
        guard !segments.isEmpty else { return }
        topUp()
        updateTimeline()
    }

    private func beginPending(_ pending: (itemID: UUID, seconds: TimeInterval)) {
        guard let index = index(of: pending.itemID) else {
            pendingStart = nil
            return finishQueue()
        }
        if let message = failures[pending.itemID] {
            pendingStart = nil
            state.lastError = message
            if let next = nextPlayableIndex(after: index, automatic: false) {
                startItem(state.items[next].id, at: 0, play: wantsToPlay)
            } else {
                finishQueue()
            }
            return
        }
        guard resolve(pending.itemID), var file = files[pending.itemID] else { return }
        let format = file.processingFormat
        let frame = max(0, min(AVAudioFramePosition(pending.seconds * format.sampleRate), file.length))
        if let download = growing[pending.itemID] {
            // Still downloading: start once a little beyond the start point has arrived, reading
            // a fresh view of the file.
            let ahead = min(file.length, frame + AVAudioFramePosition(Self.prebufferSeconds * format.sampleRate))
            guard download.isComplete || download.probablyHas(frame: ahead, of: file.length),
                  let reopened = reopen(pending.itemID, at: frame) else {
                let waiting: PlaybackState.Status = wantsToPlay ? .loading : .paused
                if state.status != waiting {
                    state.status = waiting
                    publish()
                }
                return
            }
            file = reopened
        }
        pendingStart = nil

        if !Self.sameFormat(format, connectionFormat) { reconnect(format) }
        file.framePosition = frame
        segments = [Segment(itemID: pending.itemID, startSample: 0, startFrame: file.framePosition)]
        readingID = pending.itemID
        state.duration = Double(file.length) / format.sampleRate
        state.position = Double(file.framePosition) / format.sampleRate
        state.measuredAt = now
        topUp()

        if wantsToPlay {
            do {
                if !engine.isRunning { try engine.start() }
                node.play()
                state.status = .playing
                state.measuredAt = now
                startTimer()
            } catch {
                wantsToPlay = false
                state.status = .paused
                state.lastError = "The audio output couldn't start (\(error.localizedDescription))."
            }
        } else {
            state.status = .paused
        }
        publish()
        prepareUpcoming()
    }

    private func reconnect(_ format: AVAudioFormat) {
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = gain
        connectionFormat = format
    }

    static func sameFormat(_ a: AVAudioFormat, _ b: AVAudioFormat?) -> Bool {
        guard let b else { return false }
        return a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    private func topUp() {
        guard let format = connectionFormat, !segments.isEmpty else { return }
        let target = AVAudioFramePosition(Self.aheadSeconds * format.sampleRate)
        let chunk = AVAudioFrameCount(Self.chunkSeconds * format.sampleRate)
        let played = sampleTime()

        for _ in 0..<64 where scheduledFrames - played < target && !reachedEnd {
            guard let id = readingID, let file = files[id], stalled[id] == nil else { return }

            if file.framePosition >= file.length {
                if let download = growing[id] {
                    // A partial file's length can be an estimate: confirm the end once it's all here.
                    guard download.isComplete, let reopened = reopen(id, at: file.framePosition) else {
                        stalled[id] = file.framePosition
                        return
                    }
                    if reopened.framePosition < reopened.length { continue }
                }
                guard let current = index(of: id), let nextIndex = nextPlayableIndex(after: current, automatic: true) else {
                    reachedEnd = true
                    return
                }
                let next = state.items[nextIndex]
                guard resolve(next.id), var nextFile = files[next.id] else { return }
                if growing[next.id] != nil {
                    // Opened while partial: look again, so reading sees what has arrived since.
                    guard let fresh = reopen(next.id, at: 0) else { return }
                    nextFile = fresh
                }
                // A different format can't share the connection: let this track play out.
                guard Self.sameFormat(nextFile.processingFormat, format) else { return }
                nextFile.framePosition = 0
                segments.append(Segment(itemID: next.id, startSample: scheduledFrames, startFrame: 0))
                readingID = next.id
                continue
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
            let position = file.framePosition
            var decoded = true
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                decoded = false
            }
            if !decoded || buffer.frameLength == 0 {
                if let download = growing[id] {
                    // The end of what has downloaded. Carry on now if the rest is here, else when it comes.
                    if download.isComplete, reopen(id, at: position) != nil { continue }
                    stalled[id] = position
                    return
                }
                if !decoded { failures[id] = "Part of “\(title(of: id))” couldn't be decoded." }
                file.framePosition = file.length
                continue
            }
            let scheduledGeneration = generation
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.work.async {
                    if self.generation == scheduledGeneration { self.pump() }
                }
            }
            scheduledFrames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func sampleTime() -> AVAudioFramePosition {
        if node.isPlaying, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = node.playerTime(forNodeTime: nodeTime) {
            lastSampleTime = max(0, playerTime.sampleTime)
        }
        return lastSampleTime
    }

    /// Output latency in frames — large on Bluetooth — so positions describe what is heard.
    private func latencyFrames(_ rate: Double) -> AVAudioFramePosition {
        isOffline ? 0 : AVAudioFramePosition(engine.outputNode.presentationLatency * rate)
    }

    private func currentPosition() -> TimeInterval {
        guard state.status == .playing, let rate = connectionFormat?.sampleRate, !segments.isEmpty,
              let currentID = state.currentItem?.id else { return state.position }
        let audible = max(0, sampleTime() - latencyFrames(rate))
        let segment = segments.last { $0.startSample <= audible } ?? segments[0]
        guard segment.itemID == currentID else { return state.position }
        let seconds = Double(audible - segment.startSample + segment.startFrame) / rate
        return state.duration > 0 ? min(state.duration, seconds) : seconds
    }

    private func updateTimeline() {
        guard state.status == .playing || state.status == .loading, let rate = connectionFormat?.sampleRate else { return }
        let played = sampleTime()
        let audible = max(0, played - latencyFrames(rate))
        let segmentIndex = segments.lastIndex { $0.startSample <= audible } ?? 0
        let segment = segments[segmentIndex]
        let seconds = Double(audible - segment.startSample + segment.startFrame) / rate

        if state.currentItem?.id != segment.itemID {
            state.currentIndex = index(of: segment.itemID)
            if let file = files[segment.itemID] {
                state.duration = Double(file.length) / file.processingFormat.sampleRate
            }
            state.position = seconds
            state.measuredAt = now
            publish()
            prepareUpcoming()
        } else if abs(state.position(at: now) - seconds) > 0.2 {
            state.position = state.duration > 0 ? min(seconds, state.duration) : seconds
            state.measuredAt = now
            publish()
        }
        if segmentIndex > 0 { segments.removeFirst(segmentIndex) }

        // Everything scheduled has been played.
        guard node.isPlaying, played >= scheduledFrames else { return }
        if reachedEnd {
            finishQueue()
        } else if let readingID, let file = files[readingID],
                  let resume = stalled[readingID] ?? (file.framePosition < file.length ? file.framePosition : nil) {
            // Ran dry — the download fell behind. Starting again from here waits until enough has arrived.
            state.underruns += 1
            startItem(readingID, at: Double(resume) / file.processingFormat.sampleRate, play: true)
        } else if let readingID, let current = index(of: readingID),
                  let next = nextPlayableIndex(after: current, automatic: true) {
            let nextID = state.items[next].id
            if resolve(nextID) {
                // Format change, or the next download finished after we ran dry.
                if state.status != .loading, let nextFile = files[nextID],
                   Self.sameFormat(nextFile.processingFormat, connectionFormat) {
                    state.underruns += 1
                }
                startItem(nextID, at: 0, play: true)
            } else if state.status != .loading {
                state.underruns += 1
                state.status = .loading
                publish()
            }
        }
    }

    // MARK: - Files

    /// Opens the entry's file — synchronously when the provider has it at hand. Returns whether
    /// it's open now; otherwise a fetch is under way and `pump` runs when it lands.
    @discardableResult
    private func resolve(_ id: UUID) -> Bool {
        if files[id] != nil { return true }
        guard failures[id] == nil, !resolving.contains(id),
              let track = state.items.first(where: { $0.id == id })?.track else { return false }
        if let url = provider.immediateFile(for: track) {
            do {
                files[id] = try AVAudioFile(forReading: url)
                return true
            } catch {
                failures[id] = "“\(track.title)” can't be played on this Mac."
                work.async { [self] in pump() }
                return false
            }
        }
        resolving.insert(id)
        let provider = self.provider
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<PlayableSource, Error>
            do {
                outcome = .success(try await provider.playableSource(for: track))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.work.async { self.finishResolving(id, title: track.title, outcome) }
        }
        return false
    }

    private func finishResolving(_ id: UUID, title: String, _ outcome: Result<PlayableSource, Error>) {
        resolving.remove(id)
        guard index(of: id) != nil else { return }
        switch outcome {
        case .success(let source):
            do {
                files[id] = try AVAudioFile(forReading: source.url)
                if let download = source.growing, !download.isComplete {
                    growing[id] = download
                    download.observe { [weak self] in
                        guard let self else { return }
                        self.work.async { self.downloadAdvanced() }
                    }
                }
            } catch {
                failures[id] = "“\(title)” can't be played on this Mac."
            }
        case .failure(let error):
            failures[id] = "“\(title)” couldn't be loaded: \(error.localizedDescription)"
        }
        pump()
    }

    /// Opens a downloading file afresh at `frame`. Once its download is complete, the entry is an
    /// ordinary file from then on.
    @discardableResult
    private func reopen(_ id: UUID, at frame: AVAudioFramePosition) -> AVAudioFile? {
        guard let download = growing[id] else { return files[id] }
        if let error = download.failure {
            failures[id] = "“\(title(of: id))” couldn't be loaded: \(error.localizedDescription)"
            growing[id] = nil
            stalled[id] = nil
            files[id]?.framePosition = files[id]?.length ?? 0
            return nil
        }
        let complete = download.isComplete
        guard let file = try? AVAudioFile(forReading: download.currentURL) else { return nil }
        file.framePosition = min(frame, file.length)
        files[id] = file
        stalled[id] = nil
        if complete { growing[id] = nil }
        if id == state.currentItem?.id {
            state.duration = Double(file.length) / file.processingFormat.sampleRate
        }
        return file
    }

    /// A download reported progress: carry on reading where one had run out.
    private func downloadAdvanced() {
        for (id, frame) in stalled {
            guard let download = growing[id], let file = files[id] else {
                stalled[id] = nil
                continue
            }
            let ahead = frame + AVAudioFramePosition(Self.chunkSeconds * file.processingFormat.sampleRate)
            if download.failure != nil || download.isComplete || download.probablyHas(frame: min(ahead, file.length), of: file.length) {
                reopen(id, at: frame)
            }
        }
        pump()
    }

    private func title(of id: UUID) -> String {
        state.items.first { $0.id == id }?.track.title ?? "a song"
    }

    private func prepareUpcoming() {
        guard let current = state.currentIndex else { return }
        var upcoming: [Track] = []
        var cursor = current
        for step in 0..<3 {
            guard let next = nextPlayableIndex(after: cursor, automatic: true), next != current else { break }
            if step == 0 { resolve(state.items[next].id) } else { upcoming.append(state.items[next].track) }
            cursor = next
        }
        if !upcoming.isEmpty { provider.prepare(upcoming) }

        // Close files that are behind us.
        var keep: Set<UUID> = [state.items[current].id]
        if let readingID { keep.insert(readingID) }
        if let pendingStart { keep.insert(pendingStart.itemID) }
        cursor = current
        for _ in 0..<2 {
            guard let next = nextPlayableIndex(after: cursor, automatic: true) else { break }
            keep.insert(state.items[next].id)
            cursor = next
        }
        files = files.filter { keep.contains($0.key) }
        growing = growing.filter { keep.contains($0.key) }
        stalled = stalled.filter { keep.contains($0.key) }
    }

    // MARK: - Engine events

    private func handleConfigurationChange() {
        // Output device changed (headphones, AirPods, sample rate): the engine has stopped.
        connectionFormat = nil
        guard let item = state.currentItem, state.status == .playing || state.status == .loading else { return }
        startItem(item.id, at: currentPositionIgnoringEngine(), play: wantsToPlay)
    }

    private func currentPositionIgnoringEngine() -> TimeInterval {
        state.position(at: now)
    }

    private func startTimer() {
        guard timer == nil, !isOffline else { return }
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func publish() {
        observer(state)
    }
}
