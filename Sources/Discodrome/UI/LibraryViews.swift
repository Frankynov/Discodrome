import DiscodromeCore
import SwiftUI

/// The large title a page starts with — the toolbar is left to the player.
struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct AlbumGridView: View {
    let albums: [Album]
    let title: String
    @Environment(LibraryStore.self) private var library

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18, alignment: .top)]

    var body: some View {
        Group {
            if albums.isEmpty {
                if library.isSyncing || library.connection == .connecting {
                    ProgressView(library.syncProgress ?? "Loading…")
                } else {
                    ContentUnavailableView("No Albums", systemImage: "square.stack")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PageHeader(title: title, subtitle: "\(albums.count.formatted()) album\(albums.count == 1 ? "" : "s")")
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(albums) { album in
                                AlbumTile(album: album)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(albums.isEmpty ? "" : "\(albums.count.formatted()) albums")
    }
}

enum AlbumDevicePresence {
    case complete, partial

    @MainActor
    static func of(_ album: Album, library: LibraryStore, devices: DeviceManager) -> (AlbumDevicePresence, Int, Int)? {
        guard let device = devices.primaryDevice, let contents = devices.contents[device.id],
              let tracks = library.tracksByAlbum[album.id], !tracks.isEmpty else { return nil }
        let present = tracks.reduce(0) { $0 + (contents.match.presence[$1.id] != nil ? 1 : 0) }
        guard present > 0 else { return nil }
        return (present == tracks.count ? .complete : .partial, present, tracks.count)
    }
}

struct AlbumTile: View {
    let album: Album
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceManager.self) private var devices
    @ViewState private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(coverArtID: album.coverArtID, pixelSize: 420, cornerRadius: 6)
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1.5)
                .overlay(alignment: .bottomLeading) {
                    if isHovering {
                        Button {
                            model.play(album)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .help("Play “\(album.name)”")
                        .accessibilityLabel("Play \(album.name)")
                    }
                }
                .overlay(alignment: .topTrailing) { presenceBadge }

            VStack(alignment: .leading, spacing: 1) {
                Text(album.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(album.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        // Opened with a click rather than a NavigationLink: on macOS a button keeps the mouse to
        // itself, so dragging the tile onto the device would never start.
        .onTapGesture { model.navigationPath.append(album) }
        .onHover { isHovering = $0 }
        .draggable(LibraryDragItem(kind: .album, id: album.id)) {
            ArtworkView(coverArtID: album.coverArtID, pixelSize: 420)
                .frame(width: 96, height: 96)
        }
        .contextMenu { AlbumMenuItems(album: album) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.navigationPath.append(album) }
        .accessibilityAction(named: "Play") { model.play(album) }
    }

    @ViewBuilder private var presenceBadge: some View {
        if let (state, present, total) = AlbumDevicePresence.of(album, library: library, devices: devices),
           let device = devices.primaryDevice {
            Image(systemName: state == .complete ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.5))
                .font(.system(size: 17))
                .padding(6)
                .help(state == .complete ? "On “\(device.name)”" : "\(present) of \(total) songs on “\(device.name)”")
        }
    }
}

struct AlbumMenuItems: View {
    let album: Album
    @Environment(AppModel.self) private var model
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        Button("Play", systemImage: "play") { model.play(album) }
        Button("Shuffle", systemImage: "shuffle") { model.play(album, shuffled: true) }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(album) }
        Button("Add to Up Next", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue(album) }
        if let device = devices.primaryDevice {
            Divider()
            Button("Copy to “\(device.name)”", systemImage: "arrow.down.to.line") { model.copy(album, to: device) }
        }
    }
}

struct AlbumDetailView: View {
    let album: Album
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceManager.self) private var devices
    @ViewState private var tracks: [Track] = []
    @ViewState private var version = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TrackTable(
                tracks: tracks,
                version: version,
                style: .init(visibleColumns: [.status, .number, .title, .artist, .time, .format], autosaveName: "AlbumTracks", sortable: false)
            )
        }
        .navigationTitle(album.name)
        .task(id: album.id) { await load() }
        .onChange(of: library.revision) { Task { await load() } }
    }

    private func load() async {
        tracks = await library.tracks(for: album)
        version += 1
    }

    private var metadata: String {
        var parts: [String] = []
        if let genre = album.genre, !genre.isEmpty { parts.append(genre) }
        if let year = album.year, year > 0 { parts.append(String(year)) }
        let count = tracks.isEmpty ? album.songCount : tracks.count
        let duration = tracks.isEmpty ? album.duration : tracks.reduce(0) { $0 + $1.duration }
        parts.append("\(count) song\(count == 1 ? "" : "s"), \(Formatting.longDuration(duration))")
        let formats = Set(tracks.map(\.formatLabel))
        if formats.count == 1, let format = formats.first { parts.append(format) }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 22) {
            ArtworkView(coverArtID: album.coverArtID, pixelSize: 600, cornerRadius: 8)
                .frame(width: 172, height: 172)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                .draggable(LibraryDragItem(kind: .album, id: album.id)) {
                    ArtworkView(coverArtID: album.coverArtID, pixelSize: 600)
                        .frame(width: 96, height: 96)
                }
                .help("Drag onto a device or a playlist")

            VStack(alignment: .leading, spacing: 5) {
                Text(album.name)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(album.artist)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                Text(metadata)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let device = devices.primaryDevice,
                   let (state, present, total) = AlbumDevicePresence.of(album, library: library, devices: devices) {
                    Label(
                        state == .complete ? "On “\(device.name)”" : "\(present) of \(total) songs on “\(device.name)”",
                        systemImage: state == .complete ? "checkmark.circle.fill" : "circle.lefthalf.filled"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        model.play(tracks)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.player.shuffle(tracks)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }

                    if let device = devices.primaryDevice {
                        let complete = AlbumDevicePresence.of(album, library: library, devices: devices)?.0 == .complete
                        Button {
                            model.copy(tracks, to: device)
                        } label: {
                            Label("Copy to “\(device.name)”", systemImage: "arrow.down.to.line")
                        }
                        .disabled(complete || tracks.isEmpty)
                        .help(complete ? "Every song of this album is already there." : "Copies the songs that aren't on the device yet.")
                    }
                }
                .controlSize(.large)
                .disabled(tracks.isEmpty)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

struct SongsView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Songs", subtitle: library.tracks.isEmpty ? nil : "\(library.tracks.count.formatted()) songs")
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            TrackTable(
                tracks: library.tracks,
                version: library.revision,
                style: .init(visibleColumns: [.status, .title, .artist, .album, .time, .format, .year, .genre], autosaveName: "AllSongs")
            )
            .overlay {
                if library.tracks.isEmpty {
                    if library.isSyncing { ProgressView(library.syncProgress ?? "Loading…") }
                    else { ContentUnavailableView("No Songs", systemImage: "music.note") }
                }
            }
        }
        .navigationTitle("Songs")
        .navigationSubtitle(library.tracks.isEmpty ? "" : "\(library.tracks.count.formatted()) songs")
    }
}

struct PlaylistView: View {
    let playlistID: String
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceManager.self) private var devices
    @ViewState private var tracks: [Track] = []
    @ViewState private var version = 0
    @ViewState private var errorMessage: String?

    private var playlist: Playlist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        VStack(spacing: 0) {
            if let playlist {
                HStack(alignment: .bottom, spacing: 20) {
                    ArtworkView(coverArtID: playlist.coverArtID, pixelSize: 400, cornerRadius: 8)
                        .frame(width: 120, height: 120)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .draggable(LibraryDragItem(kind: .playlist, id: playlist.id))
                        .help("Drag onto a device")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(playlist.name).font(.system(size: 22, weight: .bold)).lineLimit(2)
                        Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(Formatting.longDuration(tracks.reduce(0) { $0 + $1.duration }))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let comment = playlist.comment, !comment.isEmpty {
                            Text(comment).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack(spacing: 10) {
                            Button { model.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                            Button { model.player.shuffle(tracks) } label: { Label("Shuffle", systemImage: "shuffle") }
                            if let device = devices.primaryDevice {
                                Button { model.copy(tracks, to: device) } label: {
                                    Label("Copy to “\(device.name)”", systemImage: "arrow.down.to.line")
                                }
                            }
                        }
                        .controlSize(.large)
                        .disabled(tracks.isEmpty)
                        .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            Divider()
            TrackTable(
                tracks: tracks,
                version: version,
                style: .init(visibleColumns: [.status, .title, .artist, .album, .time, .format], autosaveName: "PlaylistTracks")
            )
            .overlay {
                if let errorMessage, tracks.isEmpty {
                    ContentUnavailableView("Couldn't Load Playlist", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                }
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .task(id: playlistID) {
            guard let playlist else { return }
            if let cached = library.cachedTracks(for: playlist) {
                tracks = cached
                version += 1
            }
            do {
                tracks = try await library.tracks(for: playlist)
                errorMessage = nil
                version += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ArtistsView: View {
    @Environment(LibraryStore.self) private var library
    @ViewState private var selection: Artist.ID?

    var body: some View {
        HSplitView {
            List(library.artists, selection: $selection) { artist in
                HStack(spacing: 8) {
                    ArtworkView(coverArtID: artist.coverArtID, pixelSize: 64, cornerRadius: 13)
                        .frame(width: 26, height: 26)
                    Text(artist.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(artist.albumCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .draggable(LibraryDragItem(kind: .artist, id: artist.id))
            }
            .listStyle(.plain)
            // Both panes fill the height; otherwise the split view shrinks to the list's rows.
            .frame(minWidth: 200, idealWidth: 260, maxWidth: 380, maxHeight: .infinity)

            Group {
                if let artist = library.artists.first(where: { $0.id == selection }) {
                    AlbumGridView(albums: library.albums(by: artist), title: artist.name)
                } else {
                    ContentUnavailableView("Select an Artist", systemImage: "music.mic")
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Artists")
        // Like Music, open on the first artist rather than an empty page.
        .onAppear { if selection == nil { selection = library.artists.first?.id } }
        .onChange(of: library.revision) { if selection == nil { selection = library.artists.first?.id } }
    }
}

struct SearchResultsView: View {
    let query: String
    @Environment(LibraryStore.self) private var library
    @ViewState private var results = LibraryStore.SearchResults()
    @ViewState private var version = 0
    @ViewState private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Search Results", subtitle: "“\(query)”")
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)
            if searched && results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                if !results.albums.isEmpty {
                    Text("Albums")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(results.albums.prefix(40)) { album in
                                AlbumTile(album: album).frame(width: 132)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .frame(height: 196)
                }
                Text(results.tracks.isEmpty ? "" : "Songs")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                TrackTable(
                    tracks: results.tracks,
                    version: version,
                    style: .init(visibleColumns: [.status, .title, .artist, .album, .time, .format], autosaveName: "SearchTracks")
                )
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle("“\(query)”")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let found = await library.search(query)
            guard !Task.isCancelled else { return }
            results = found
            version += 1
            searched = true
        }
    }
}
