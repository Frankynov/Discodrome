import AppKit
import DiscodromeCore
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case recentlyAdded, artists, albums, songs
    case playlist(String)
    case device(String)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case info = "Info"
    case lyrics = "Lyrics"
    case upNext = "Up Next"

    var id: String { rawValue }
}

struct DeletionRequest: Identifiable {
    let id = UUID()
    let device: Device
    let tracks: [Track]
}

/// Owns the services and the window's navigation state.
@MainActor @Observable
final class AppModel {
    let settings: AppSettings
    let library: LibraryStore
    let player: PlayerController
    let devices: DeviceManager
    let transfers: TransferManager

    var sidebarSelection: SidebarItem? = .albums {
        didSet {
            guard oldValue != sidebarSelection else { return }
            navigationPath = NavigationPath()
            selectedTracks = []
        }
    }
    var navigationPath = NavigationPath()
    var searchText = ""
    var showInspector = true
    /// Whether the inspector's column is open far enough for its tabs in the toolbar — kept up to
    /// date by the main window as the column animates.
    var inspectorFitsTabs = true
    var inspectorTab: InspectorTab = .info
    /// The selection in whichever song list has focus; the inspector describes it.
    var selectedTracks: [Track] = []
    /// Set to make the visible song list scroll to and select this track.
    var revealTrackID: String?
    var deletionRequest: DeletionRequest?
    /// Whether the device page shows its Transfers list rather than its songs. Kept here so it
    /// survives navigating away, and so starting a copy can switch to it.
    var deviceShowsTransfers = false
    /// Opens the Settings window; set by the main window, which can reach SwiftUI's action.
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    @ObservationIgnored private var lyricsCache: [String: Lyrics] = [:]

    init() {
        settings = AppSettings()
        library = LibraryStore()
        player = PlayerController(settings: settings)
        devices = DeviceManager(settings: settings, library: library)
        transfers = TransferManager(settings: settings, library: library, devices: devices, player: player)
        applyServerSettings()
        devices.start()
        KeyMonitor.install(player: player)
        DevSnapshots.runIfRequested(self)
    }

    func applyServerSettings() {
        library.configure(settings.credentials)
        player.setServer(library.client)
    }

    // MARK: Actions shared by menus, tables and tiles

    func play(_ tracks: [Track], startingAt index: Int = 0) {
        player.play(tracks, startingAt: index)
    }

    func play(_ album: Album, shuffled: Bool = false) {
        Task {
            let tracks = await library.tracks(for: album)
            if shuffled { player.shuffle(tracks) } else { player.play(tracks) }
        }
    }

    func playNext(_ album: Album) {
        Task { player.playNext(await library.tracks(for: album)) }
    }

    func addToQueue(_ album: Album) {
        Task { player.addToQueue(await library.tracks(for: album)) }
    }

    func copy(_ tracks: [Track], to device: Device? = nil) {
        guard let device = device ?? devices.primaryDevice else { return }
        transfers.copy(tracks, to: device)
    }

    func copy(_ album: Album, to device: Device? = nil) {
        Task { copy(await library.tracks(for: album), to: device) }
    }

    func copy(_ items: [LibraryDragItem], to device: Device? = nil) {
        Task { copy(await tracks(for: items), to: device) }
    }

    func tracks(for items: [LibraryDragItem]) async -> [Track] {
        var result: [Track] = []
        for item in items {
            switch item.kind {
            case .track:
                if let track = library.trackByID[item.id] { result.append(track) }
            case .album:
                if let album = library.album(id: item.id) { result += await library.tracks(for: album) }
            case .playlist:
                if let playlist = library.playlists.first(where: { $0.id == item.id }) {
                    result += (try? await library.tracks(for: playlist)) ?? []
                }
            case .artist:
                if let artist = library.artists.first(where: { $0.id == item.id }) {
                    for album in library.albums(by: artist) { result += await library.tracks(for: album) }
                }
            }
        }
        return result
    }

    func requestDeletion(_ tracks: [Track], from device: Device) {
        let onDevice = tracks.filter { $0.fileURL != nil }
        guard !onDevice.isEmpty else { return }
        deletionRequest = DeletionRequest(device: device, tracks: onDevice)
    }

    func confirmDeletion(_ request: DeletionRequest) {
        devices.delete(request.tracks.compactMap(\.path), from: request.device)
        selectedTracks = []
    }

    func revealInFinder(_ tracks: [Track]) {
        let urls = tracks.compactMap(\.fileURL)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func showInfo() {
        showInspector = true
        inspectorTab = .info
    }

    func goToAlbum(of track: Track) {
        guard let album = library.album(id: track.albumID) else { return }
        searchText = ""
        if sidebarSelection != .albums { sidebarSelection = .albums }
        navigationPath = NavigationPath([album])
        revealTrackID = track.id
    }

    func goToCurrentSong() {
        guard let track = player.currentTrack else { return }
        if track.isServerTrack {
            goToAlbum(of: track)
        } else if let device = devices.primaryDevice {
            sidebarSelection = .device(device.id)
            revealTrackID = track.id
        }
    }

    /// The library song a track corresponds to: itself for server tracks, the matched song for
    /// files on a device.
    func libraryTrack(for track: Track) -> Track? {
        if track.isServerTrack { return track }
        guard let path = track.path else { return nil }
        for (id, contents) in devices.contents {
            guard devices.devices.contains(where: { $0.id == id }) else { continue }
            if let trackID = contents.match.trackForFile[path], let match = library.trackByID[trackID] { return match }
        }
        return nil
    }

    func artworkID(for track: Track) -> String? {
        track.coverArtID ?? libraryTrack(for: track)?.coverArtID
    }

    /// Lyrics from an .lrc file beside a device file, else from the server.
    func lyrics(for track: Track) async -> Lyrics? {
        if let cached = lyricsCache[track.id] { return cached }
        var found: Lyrics?
        if let url = track.fileURL {
            let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
            found = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: sidecar) else { return nil }
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                return text.isEmpty ? nil : LRCParser.parse(text)
            }.value
        }
        if found == nil, let serverTrack = libraryTrack(for: track), let client = library.client {
            found = try? await client.lyrics(for: serverTrack, structured: library.supportsStructuredLyrics)
        }
        if let found { lyricsCache[track.id] = found }
        return found
    }

    func eject(_ device: Device) {
        guard !transfers.isActive(on: device.id) else {
            devices.lastError = "\(device.name) is still being written to. Stop copying before ejecting it."
            return
        }
        if player.currentTrack?.fileURL?.path.hasPrefix(device.url.path) == true {
            player.stop()
        }
        Task { await devices.eject(device) }
    }
}

/// Space plays and pauses, as in Music — except while typing or when a control has focus.
@MainActor
enum KeyMonitor {
    private static var token: Any?

    static func install(player: PlayerController) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard event.keyCode == 49,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                      let window = event.window, window.isKeyWindow,
                      window.identifier?.rawValue.hasPrefix("main") == true else { return false }
                if let responder = window.firstResponder {
                    if responder is NSText { return false }
                    if responder is NSControl, !(responder is NSTableView) { return false }
                }
                player.togglePlayPause()
                return true
            }
            return consumed ? nil : event
        }
    }
}
