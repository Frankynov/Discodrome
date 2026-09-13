import DiscodromeCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceManager.self) private var devices
    @Environment(TransferManager.self) private var transfers
    @Environment(PlayerController.self) private var player
    @Environment(\.openSettings) private var openSettings
    /// Updated on every frame of the inspector's animation; a class, so that doesn't redraw the window.
    @ViewState private var widths = ColumnWidths()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            // With no toolbar background (below), content has to stop at the toolbar instead of
            // scrolling beneath the player's controls.
            DetailView()
                .clipped()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.columns = $0; fitInspectorTabs() }
        .inspector(isPresented: $model.showInspector) {
            // Its content is laid out at the column's full width even while the column animates, so
            // its width is the one the column is heading for.
            InspectorView()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.inspector = $0; fitInspectorTabs() }
                .inspectorColumnWidth(min: 270, ideal: 310, max: 440)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.window = $0; fitInspectorTabs() }
        // At window level so the controls stay put while navigating into an album; pages show
        // their own large titles, which leaves the toolbar to the player.
        .toolbar(id: "player") {
            PlayerToolbarContent(
                player: player,
                isPlaying: player.isPlaying,
                hasQueue: !player.state.items.isEmpty,
                isShuffled: player.isShuffled,
                repeatMode: player.state.repeatMode,
                showInspector: $model.showInspector
            )
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
        .onChange(of: library.revision) { devices.rematchAll() }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { model.deletionRequest != nil }, set: { if !$0 { model.deletionRequest = nil } }),
            titleVisibility: .visible,
            presenting: model.deletionRequest
        ) { request in
            Button("Delete", role: .destructive) { model.confirmDeletion(request) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The files and their lyrics are removed from the card. This can't be undone.")
        }
        .alert(
            "Not enough space on “\(transfers.planNeedingConfirmation?.device.name ?? "the device")”",
            isPresented: Binding(get: { transfers.planNeedingConfirmation != nil }, set: { if !$0 { transfers.planNeedingConfirmation = nil } }),
            presenting: transfers.planNeedingConfirmation
        ) { plan in
            Button("Copy What Fits") { transfers.startFittingPart(of: plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text("These \(plan.jobs.count) songs need about \(Formatting.bytes(plan.bytes)), but only \(Formatting.bytes(plan.device.available)) is free.")
        }
        .alert(
            "Device",
            isPresented: Binding(get: { devices.lastError != nil }, set: { if !$0 { devices.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(devices.lastError ?? "")
        }
        // Window-wide, under the sidebar, content and inspector — like iTunes' capacity bar. As an
        // inset of the split view itself it also stays visible on pages pushed onto the stack.
        // No toolbar background. On macOS 26 the content column's toolbar band starts a couple of
        // points inside the sidebar, because content extends under it — a visibly misaligned edge
        // and line. Without the band the column dividers run cleanly to the top of the window.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .safeAreaInset(edge: .bottom, spacing: 0) { DeviceBar() }
        .onAppear { model.openSettingsWindow = { openSettings() } }
    }

    /// The inspector's tabs leave once the closing column is narrower than they need, and come back as
    /// the opening one comes to rest. Adding a toolbar item costs the animation a frame, which shows
    /// least where the column moves slowest; and sooner, the tabs would shove the other controls aside.
    private func fitInspectorTabs() {
        guard widths.window > 0, widths.columns > 0, widths.inspector > 0 else { return }
        let open = widths.window - widths.columns
        let fits = model.inspectorFitsTabs
            ? open >= InspectorView.widthForTabs
            : open >= max(InspectorView.widthForTabs, widths.inspector - 12)
        // Only on a change, and not read by this view's body: the window mustn't redraw for it.
        if fits != model.inspectorFitsTabs { model.inspectorFitsTabs = fits }
    }

    private var deletionTitle: String {
        guard let request = model.deletionRequest else { return "" }
        let what = request.tracks.count == 1 ? "“\(request.tracks[0].title)”" : "\(request.tracks.count) songs"
        return "Delete \(what) from “\(request.device.name)”?"
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section(library.serverInfo?.type.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Library") {
                Label("Recently Added", systemImage: "clock").tag(SidebarItem.recentlyAdded)
                Label("Artists", systemImage: "music.mic").tag(SidebarItem.artists)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
                Label("Songs", systemImage: "music.note").tag(SidebarItem.songs)
            }

            if !library.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(library.playlists) { playlist in
                        PlaylistSidebarRow(playlist: playlist)
                            .tag(SidebarItem.playlist(playlist.id))
                    }
                }
            }

            Section("Devices") {
                if devices.devices.isEmpty {
                    Label("No Device Connected", systemImage: "cable.connector")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(devices.devices) { device in
                    DeviceSidebarRow(device: device)
                        .tag(SidebarItem.device(device.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { LibraryStatusFooter() }
    }
}

struct PlaylistSidebarRow: View {
    let playlist: Playlist
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @ViewState private var isTargeted = false

    var body: some View {
        Label(playlist.name, systemImage: "music.note.list")
            .draggable(LibraryDragItem(kind: .playlist, id: playlist.id))
            .dropDestination(for: LibraryDragItem.self) { items, _ in
                Task {
                    let tracks = await model.tracks(for: items).filter(\.isServerTrack)
                    guard !tracks.isEmpty else { return }
                    try? await library.addToPlaylist(playlist, tracks: tracks)
                }
                return true
            } isTargeted: { isTargeted = $0 }
            .listRowBackground(isTargeted ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25)).padding(.horizontal, 8) : nil)
    }
}

struct DeviceSidebarRow: View {
    let device: Device
    @Environment(AppModel.self) private var model
    @Environment(DeviceManager.self) private var devices
    @Environment(TransferManager.self) private var transfers
    @ViewState private var isTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(device.name).lineLimit(1)
            } icon: {
                if device.isDISC {
                    DiscGlyph(isSpinning: transfers.isActive(on: device.id))
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "sdcard")
                }
            }
            Spacer(minLength: 4)
            if transfers.isActive(on: device.id) {
                ProgressView(value: transfers.progress.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
            Button {
                model.eject(device)
            } label: {
                Image(systemName: "eject.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Eject “\(device.name)”")
            .accessibilityLabel("Eject \(device.name)")
        }
        .dropDestination(for: LibraryDragItem.self) { items, _ in
            model.copy(items, to: device)
            return true
        } isTargeted: { isTargeted = $0 }
        .listRowBackground(isTargeted ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25)).padding(.horizontal, 8) : nil)
        .contextMenu {
            Button("Eject “\(device.name)”", systemImage: "eject") { model.eject(device) }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([device.url]) }
            Button("Rescan", systemImage: "arrow.clockwise") { devices.scan(device) }
            Divider()
            Toggle("This Is a SNOWSKY DISC", isOn: Binding(get: { device.isDISC }, set: { devices.setIsDISC($0, for: device) }))
        }
    }
}

struct LibraryStatusFooter: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            switch library.connection {
            case .notConfigured:
                SettingsLink {
                    Label("Connect to Navidrome…", systemImage: "server.rack")
                }
                .buttonStyle(.borderless)
            case .offline(let message):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("Server unreachable").lineLimit(1)
                    Spacer()
                    Button("Retry") { Task { await library.refresh() } }
                        .buttonStyle(.borderless)
                }
                .help(message)
            case .connecting, .online:
                if library.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(library.syncProgress ?? "Updating…").lineLimit(1)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.navigationPath) {
            root
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
        }
    }

    @ViewBuilder private var root: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            SearchResultsView(query: query)
        } else {
            switch model.sidebarSelection {
            case .device(let id):
                DeviceView(deviceID: id)
            case .playlist(let id):
                PlaylistView(playlistID: id)
            default:
                if case .notConfigured = library.connection, library.albums.isEmpty {
                    WelcomeView()
                } else {
                    switch model.sidebarSelection {
                    case .recentlyAdded: AlbumGridView(albums: library.recentlyAdded, title: "Recently Added")
                    case .artists: ArtistsView()
                    case .songs: SongsView()
                    default: AlbumGridView(albums: library.albums, title: "Albums")
                    }
                }
            }
        }
    }
}

struct WelcomeView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connect to Your Music Server", systemImage: "server.rack")
        } description: {
            Text("Discodrome plays and copies music from Navidrome, or any Subsonic-compatible server.")
        } actions: {
            SettingsLink {
                Text("Open Settings…")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// The widths that tell how far open the inspector is, and how far it's going.
private final class ColumnWidths {
    var columns: CGFloat = 0
    var window: CGFloat = 0
    var inspector: CGFloat = 0
}
