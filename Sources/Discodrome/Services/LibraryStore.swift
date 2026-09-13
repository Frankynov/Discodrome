import DiscodromeCore
import Foundation
import Observation

/// What was last fetched from the server, kept on disk so the library appears instantly at
/// launch and stays browsable offline.
struct LibrarySnapshot: Codable, Sendable {
    var albums: [Album]
    var artists: [Artist]
    var tracks: [Track]
    var playlists: [Playlist]
    var syncedAt: Date
}

/// A snapshot sorted and indexed off the main thread.
struct IndexedLibrary: Sendable {
    let albums: [Album]
    let artists: [Artist]
    let tracks: [Track]
    let playlists: [Playlist]
    let tracksByAlbum: [String: [Track]]
    let trackByID: [String: Track]
    let syncedAt: Date

    init(_ snapshot: LibrarySnapshot) {
        albums = snapshot.albums
            .map { ($0, $0.artist.librarySortKey, $0.name.librarySortKey) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1.localizedStandardCompare(rhs.1) == .orderedAscending }
                if (lhs.0.year ?? 0) != (rhs.0.year ?? 0) { return (lhs.0.year ?? 0) < (rhs.0.year ?? 0) }
                return lhs.2.localizedStandardCompare(rhs.2) == .orderedAscending
            }
            .map(\.0)
        artists = snapshot.artists
            .map { ($0, $0.name.librarySortKey) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            .map(\.0)
        tracks = snapshot.tracks
            .map { ($0, $0.albumArtist.librarySortKey, $0.album.librarySortKey) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
                if (lhs.0.discNumber ?? 1) != (rhs.0.discNumber ?? 1) { return (lhs.0.discNumber ?? 1) < (rhs.0.discNumber ?? 1) }
                return (lhs.0.trackNumber ?? 0) < (rhs.0.trackNumber ?? 0)
            }
            .map(\.0)
        var byAlbum: [String: [Track]] = [:]
        var byID: [String: Track] = [:]
        byID.reserveCapacity(tracks.count)
        for track in tracks {
            byID[track.id] = track
            if let albumID = track.albumID { byAlbum[albumID, default: []].append(track) }
        }
        tracksByAlbum = byAlbum
        trackByID = byID
        playlists = snapshot.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        syncedAt = snapshot.syncedAt
    }
}

@MainActor @Observable
final class LibraryStore {
    enum Connection: Equatable {
        case notConfigured
        case connecting
        case online(ServerInfo)
        case offline(String)
    }

    private(set) var connection: Connection = .notConfigured
    private(set) var isSyncing = false
    private(set) var syncProgress: String?
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    private(set) var tracksByAlbum: [String: [Track]] = [:]
    private(set) var trackByID: [String: Track] = [:]
    private(set) var lastSync: Date?
    /// Bumped whenever `tracks` is replaced, so table views can tell cheaply.
    private(set) var revision = 0
    private(set) var client: SubsonicClient?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var playlistCache: [String: [Track]] = [:]

    var serverInfo: ServerInfo? {
        if case .online(let info) = connection { return info }
        return nil
    }

    var supportsStructuredLyrics: Bool { serverInfo?.extensions.contains("songLyrics") ?? false }

    var recentlyAdded: [Album] {
        albums.filter { $0.created != nil }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    /// For pictures meant for the public, whose playlist names are personal. Until the next sync.
    func hidePlaylists() {
        playlists = []
    }

    func configure(_ credentials: ServerCredentials?) {
        refreshTask?.cancel()
        playlistCache = [:]
        guard let credentials else {
            client = nil
            apply(IndexedLibrary(LibrarySnapshot(albums: [], artists: [], tracks: [], playlists: [], syncedAt: .distantPast)))
            lastSync = nil
            connection = .notConfigured
            ArtworkLoader.shared.configure(nil)
            return
        }
        let client = SubsonicClient(credentials: credentials)
        self.client = client
        ArtworkLoader.shared.configure(client)
        connection = .connecting
        refreshTask = Task {
            if let snapshot = await Self.loadSnapshot(key: credentials.cacheKey), !Task.isCancelled {
                let indexed = await Task.detached(priority: .userInitiated) { IndexedLibrary(snapshot) }.value
                if !Task.isCancelled { apply(indexed) }
            }
            await refresh()
        }
    }

    func refresh() async {
        guard let client, !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            syncProgress = nil
        }
        do {
            syncProgress = "Connecting…"
            let info = try await client.ping()
            connection = .online(info)
            syncProgress = "Loading albums…"
            async let albumsResult = client.allAlbums()
            async let artistsResult = client.artists()
            async let playlistsResult = client.playlists()
            let (albums, artists, playlists) = try await (albumsResult, artistsResult, playlistsResult)

            syncProgress = "Loading songs…"
            var tracks = try await client.allSongs { count in
                Task { @MainActor [weak self] in self?.syncProgress = "Loading songs… \(count.formatted())" }
            }
            if tracks.isEmpty && !albums.isEmpty {
                tracks = try await fetchAlbumByAlbum(client, albums)
            }
            let snapshot = LibrarySnapshot(albums: albums, artists: artists, tracks: tracks, playlists: playlists, syncedAt: Date())
            let indexed = await Task.detached(priority: .userInitiated) { IndexedLibrary(snapshot) }.value
            guard !Task.isCancelled, client === self.client else { return }
            apply(indexed)
            playlistCache = [:]
            await Self.saveSnapshot(snapshot, key: client.credentials.cacheKey)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard client === self.client else { return }
            connection = .offline(error.localizedDescription)
        }
    }

    /// Servers that don't enumerate songs through search3 get asked album by album.
    private func fetchAlbumByAlbum(_ client: SubsonicClient, _ albums: [Album]) async throws -> [Track] {
        var tracks: [Track] = []
        var done = 0
        try await withThrowingTaskGroup(of: [Track].self) { group in
            var iterator = albums.makeIterator()
            for _ in 0..<8 {
                guard let album = iterator.next() else { break }
                group.addTask { try await client.album(id: album.id).tracks }
            }
            while let batch = try await group.next() {
                tracks += batch
                done += 1
                if done % 25 == 0 { syncProgress = "Loading songs… album \(done) of \(albums.count)" }
                if let album = iterator.next() {
                    group.addTask { try await client.album(id: album.id).tracks }
                }
            }
        }
        return tracks
    }

    private func apply(_ indexed: IndexedLibrary) {
        albums = indexed.albums
        artists = indexed.artists
        tracks = indexed.tracks
        playlists = indexed.playlists
        tracksByAlbum = indexed.tracksByAlbum
        trackByID = indexed.trackByID
        lastSync = indexed.syncedAt == .distantPast ? nil : indexed.syncedAt
        revision += 1
    }

    // MARK: Lookups

    func tracks(for album: Album) async -> [Track] {
        if let known = tracksByAlbum[album.id], !known.isEmpty { return known }
        guard let client, let fetched = try? await client.album(id: album.id).tracks else { return [] }
        tracksByAlbum[album.id] = fetched
        return fetched
    }

    func cachedTracks(for playlist: Playlist) -> [Track]? { playlistCache[playlist.id] }

    func tracks(for playlist: Playlist) async throws -> [Track] {
        guard let client else { return playlistCache[playlist.id] ?? [] }
        let fetched = try await client.playlist(id: playlist.id).tracks
        // Prefer the library's copy of each track so device matching sees the same values.
        let resolved = fetched.map { trackByID[$0.id] ?? $0 }
        playlistCache[playlist.id] = resolved
        return resolved
    }

    func albums(by artist: Artist) -> [Album] {
        albums.filter { $0.artistID == artist.id || $0.artist == artist.name }
            .sorted { ($0.year ?? 0, $0.name) < ($1.year ?? 0, $1.name) }
    }

    func album(id: String?) -> Album? {
        guard let id else { return nil }
        return albums.first { $0.id == id }
    }

    func addToPlaylist(_ playlist: Playlist, tracks: [Track]) async throws {
        guard let client else { return }
        try await client.addToPlaylist(id: playlist.id, songIDs: tracks.map(\.id))
        playlistCache[playlist.id] = nil
        playlists = try await client.playlists().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Search

    struct SearchResults: Sendable {
        var artists: [Artist] = []
        var albums: [Album] = []
        var tracks: [Track] = []
        var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }
    }

    /// Runs off the main thread: a library of tens of thousands of songs takes a moment.
    func search(_ text: String) async -> SearchResults {
        let (artists, albums, tracks) = (self.artists, self.albums, self.tracks)
        return await Task.detached(priority: .userInitiated) {
            Self.search(text, artists: artists, albums: albums, tracks: tracks)
        }.value
    }

    /// Every word must appear somewhere in the item — "rivers tide" finds Tide by Glass Rivers.
    nonisolated static func search(_ text: String, artists: [Artist], albums: [Album], tracks: [Track]) -> SearchResults {
        let words = text.split(separator: " ").map { String($0) }
        guard !words.isEmpty else { return SearchResults() }
        func matches(_ fields: String...) -> Bool {
            words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
        }
        var results = SearchResults()
        results.artists = artists.filter { matches($0.name) }
        results.albums = albums.filter { matches($0.name, $0.artist) }
        results.tracks = tracks.filter { matches($0.title, $0.artist, $0.album) }
        return results
    }

    // MARK: Persistence

    private nonisolated static func snapshotURL(key: String) -> URL {
        Paths.applicationSupport.appending(path: "Library/\(key).json")
    }

    private nonisolated static func loadSnapshot(key: String) async -> LibrarySnapshot? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: snapshotURL(key: key)) else { return nil }
            return try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
        }.value
    }

    private nonisolated static func saveSnapshot(_ snapshot: LibrarySnapshot, key: String) async {
        await Task.detached(priority: .utility) {
            let url = snapshotURL(key: key)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }.value
    }
}
