import AppKit
import DiscodromeCore
import MediaPlayer
import Observation
import Synchronization

/// Server tracks go through the download cache; device and local files play in place.
final class RoutingAudioProvider: AudioFileProvider {
    private let server = Mutex<ServerAudioProvider?>(nil)

    func setServer(_ provider: ServerAudioProvider?) {
        server.withLock { $0 = provider }
    }

    var serverProvider: ServerAudioProvider? { server.withLock { $0 } }

    func localFile(for track: Track) async throws -> URL {
        if let url = track.fileURL { return url }
        guard let provider = serverProvider else { throw URLError(.notConnectedToInternet) }
        return try await provider.localFile(for: track)
    }

    func immediateFile(for track: Track) -> URL? {
        track.fileURL ?? serverProvider?.immediateFile(for: track)
    }

    func playableSource(for track: Track) async throws -> PlayableSource {
        if let url = track.fileURL { return PlayableSource(url: url) }
        guard let provider = serverProvider else { throw URLError(.notConnectedToInternet) }
        return try await provider.playableSource(for: track)
    }

    func prepare(_ tracks: [Track]) {
        serverProvider?.prepare(tracks)
    }
}

/// The app's face of the gapless engine: queue editing, shuffle, Now Playing in Control
/// Centre, media keys, and scrobbling plays back to Navidrome.
@MainActor @Observable
final class PlayerController {
    private(set) var state = PlaybackState()
    private(set) var isShuffled = false
    var volume: Double {
        didSet {
            engine.setVolume(Self.gain(for: volume))
            settings.volume = volume
        }
    }

    @ObservationIgnored let provider = RoutingAudioProvider()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var engine: GaplessPlayer!
    @ObservationIgnored private var orderedItems: [PlayerItem] = []
    @ObservationIgnored private var client: SubsonicClient?
    @ObservationIgnored private var announcedItem: UUID?
    @ObservationIgnored private var scrobbledItems: Set<UUID> = []
    @ObservationIgnored private var scrobbleTimer: Timer?
    @ObservationIgnored private var artwork: NSImage?

    init(settings: AppSettings) {
        self.settings = settings
        self.volume = settings.volume
        engine = GaplessPlayer(provider: provider) { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(state) }
            }
        }
        // DISCODROME_MUTE silences development runs without touching the saved volume.
        engine.setVolume(ProcessInfo.processInfo.environment["DISCODROME_MUTE"] == nil ? Self.gain(for: volume) : 0)
        engine.setRepeatMode(settings.repeatMode)
        configureRemoteCommands()
    }

    /// Sliders feel linear when the gain follows a square law.
    static func gain(for slider: Double) -> Float { Float(slider * slider) }

    func setServer(_ client: SubsonicClient?) {
        self.client = client
        provider.setServer(client.map {
            ServerAudioProvider(
                client: $0,
                directory: Paths.caches.appending(path: "Tracks/\($0.credentials.cacheKey)", directoryHint: .isDirectory),
                limitBytes: Int64(settings.cacheLimitGB) << 30
            )
        })
    }

    var currentTrack: Track? { state.currentItem?.track }
    var isPlaying: Bool { state.status == .playing || state.status == .loading }

    var upNext: [PlayerItem] {
        guard let index = state.currentIndex else { return [] }
        return Array(state.items.dropFirst(index + 1))
    }

    // MARK: Queue

    func play(_ tracks: [Track], startingAt index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        let items = tracks.map { PlayerItem($0) }
        orderedItems = items
        if isShuffled {
            var rest = items
            let first = rest.remove(at: index)
            engine.play([first] + rest.shuffled(), startAt: 0)
        } else {
            engine.play(items, startAt: index)
        }
    }

    func shuffle(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        isShuffled = true
        play(tracks, startingAt: Int.random(in: tracks.indices))
    }

    func playNext(_ tracks: [Track]) {
        guard let current = state.currentIndex else { return play(tracks) }
        let items = tracks.map { PlayerItem($0) }
        var queue = state.items
        queue.insert(contentsOf: items, at: current + 1)
        if let ordered = orderedItems.firstIndex(where: { $0.id == state.items[current].id }) {
            orderedItems.insert(contentsOf: items, at: ordered + 1)
        }
        engine.updateQueue(queue)
    }

    func addToQueue(_ tracks: [Track]) {
        guard state.currentIndex != nil else { return play(tracks) }
        let items = tracks.map { PlayerItem($0) }
        orderedItems += items
        engine.updateQueue(state.items + items)
    }

    func removeFromQueue(_ ids: Set<UUID>) {
        let currentID = state.currentItem?.id
        let remaining = state.items.filter { !ids.contains($0.id) || $0.id == currentID }
        orderedItems.removeAll { ids.contains($0.id) && $0.id != currentID }
        engine.updateQueue(remaining)
    }

    /// Moves entries within Up Next; offsets are relative to `upNext`.
    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard let current = state.currentIndex else { return }
        var upcoming = upNext
        upcoming.move(fromOffsets: source, toOffset: destination)
        engine.updateQueue(Array(state.items.prefix(current + 1)) + upcoming)
    }

    func clearUpNext() {
        guard let current = state.currentIndex else { return }
        engine.updateQueue(Array(state.items.prefix(current + 1)))
    }

    // MARK: Transport

    func togglePlayPause() {
        guard !state.items.isEmpty else { return }
        engine.togglePlayPause()
    }

    func next() { engine.next() }
    func previous() { engine.previous() }
    func jump(to index: Int) { engine.jump(to: index) }
    func stop() { engine.stop() }

    func seek(to seconds: TimeInterval) {
        engine.seek(to: seconds)
        // Show the new position straight away; the engine confirms a moment later.
        state.position = seconds
        state.measuredAt = ProcessInfo.processInfo.systemUptime
    }

    func skip(by seconds: TimeInterval) {
        seek(to: max(0, state.position() + seconds))
    }

    func adjustVolume(by delta: Double) {
        volume = min(1, max(0, volume + delta))
    }

    func toggleShuffle() {
        isShuffled.toggle()
        guard let current = state.currentItem else { return }
        if isShuffled {
            orderedItems = state.items
            engine.updateQueue([current] + state.items.filter { $0.id != current.id }.shuffled())
        } else {
            let ordered = orderedItems.filter { item in state.items.contains { $0.id == item.id } }
            engine.updateQueue(ordered.isEmpty ? state.items : ordered)
        }
    }

    func setRepeatMode(_ mode: RepeatMode) {
        settings.repeatMode = mode
        state.repeatMode = mode
        engine.setRepeatMode(mode)
    }

    func cycleRepeatMode() {
        let next: RepeatMode = switch state.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        settings.repeatMode = next
        state.repeatMode = next
        engine.setRepeatMode(next)
    }

    // MARK: Engine updates

    private func apply(_ newState: PlaybackState) {
        let previousItem = state.currentItem?.id
        let previousStatus = state.status
        state = newState
        if newState.currentItem?.id != previousItem {
            loadArtwork()
        }
        if newState.currentItem?.id != previousItem || newState.status != previousStatus {
            updateScrobbling()
        }
        updateNowPlaying()
    }

    private func loadArtwork() {
        artwork = nil
        guard let id = state.currentItem?.track.coverArtID else { return }
        let itemID = state.currentItem?.id
        Task {
            let image = await ArtworkLoader.shared.image(id, size: 600)
            guard state.currentItem?.id == itemID else { return }
            artwork = image
            updateNowPlaying()
        }
    }

    /// Snapshot walkthroughs play real songs: they mustn't end up in the server's listening history.
    private static let scrobblingAllowed = ProcessInfo.processInfo.environment["DISCODROME_SNAPSHOTS"] == nil

    private func updateScrobbling() {
        scrobbleTimer?.invalidate()
        scrobbleTimer = nil
        guard settings.scrobble, Self.scrobblingAllowed, state.status == .playing, let item = state.currentItem,
              item.track.isServerTrack, let client else { return }
        if announcedItem != item.id {
            announcedItem = item.id
            let id = item.track.id
            Task.detached { try? await client.scrobble(id: id, submission: false) }
        }
        scrobbleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.submitScrobbleIfDue() }
        }
    }

    /// A play counts after half the song or four minutes, whichever comes first.
    private func submitScrobbleIfDue() {
        guard let item = state.currentItem, !scrobbledItems.contains(item.id), let client,
              state.duration >= 30, state.position() >= min(240, state.duration / 2) else { return }
        scrobbledItems.insert(item.id)
        let id = item.track.id
        Task.detached { try? await client.scrobble(id: id, submission: true) }
    }

    // MARK: Now Playing & media keys

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = state.currentItem?.track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position(),
            MPNowPlayingInfoPropertyPlaybackRate: state.status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(artwork)
        }
        center.nowPlayingInfo = info
        center.playbackState = switch state.status {
        case .playing, .loading: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }

    /// Made outside the main actor: MediaPlayer asks for the image on its own queue, where a
    /// closure formed on the main actor would trap.
    private nonisolated static func nowPlayingArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func configureRemoteCommands() {
        Self.registerRemoteCommands(for: self)
    }

    /// Registered outside the main actor for the same reason; each handler hops back to it.
    private nonisolated static func registerRemoteCommands(for controller: PlayerController) {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (PlayerController) -> Void) {
            command.isEnabled = true
            command.addTarget { _ in
                Task { @MainActor in action(controller) }
                return .success
            }
        }
        on(center.playCommand) { if $0.state.status != .playing { $0.togglePlayPause() } }
        on(center.pauseCommand) { if $0.state.status == .playing { $0.togglePlayPause() } }
        on(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        on(center.nextTrackCommand) { $0.next() }
        on(center.previousTrackCommand) { $0.previous() }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in controller.seek(to: position) }
            return .success
        }
    }
}
