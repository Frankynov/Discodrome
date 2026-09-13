import CryptoKit
import Foundation

/// Where the server is and how to sign requests. Holds the salted token rather than the
/// password: Subsonic accepts a reused salt, so the password itself never needs storing.
public struct ServerCredentials: Codable, Hashable, Sendable {
    public var serverURL: URL
    public var username: String
    public var token: String
    public var salt: String

    public init(serverURL: URL, username: String, token: String, salt: String) {
        self.serverURL = serverURL; self.username = username; self.token = token; self.salt = salt
    }

    public init(serverURL: URL, username: String, password: String) {
        let salt = Self.makeSalt()
        self.init(serverURL: serverURL, username: username, token: Self.token(password: password, salt: salt), salt: salt)
    }

    /// `md5(password + salt)`, lower-case hex — Subsonic API 1.13+ token authentication.
    public static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func makeSalt() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }

    /// Stable, filesystem-safe identifier for this server and account, used to name caches.
    public var cacheKey: String {
        let raw = serverURL.absoluteString.lowercased() + "|" + username
        return SHA256.hash(data: Data(raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts what people type: "music.home:4533", "http://10.0.0.5:4533/", "https://host/navidrome".
    public static func normalizedServerURL(_ text: String) -> URL? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "http://" + string }
        while string.hasSuffix("/") { string.removeLast() }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

public enum SubsonicError: LocalizedError, Equatable {
    case http(Int)
    case api(code: Int, message: String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "The server answered HTTP \(status)."
        case .api(let code, let message):
            switch code {
            case 40: return "Wrong username or password."
            case 41: return "This server doesn't accept token authentication."
            case 50: return "This account isn't allowed to do that."
            case 70: return "Not found on the server."
            default: return message
            }
        case .decoding(let detail): return "The server's answer couldn't be read (\(detail))."
        }
    }
}

public struct ServerInfo: Sendable, Equatable {
    public var type: String?
    public var version: String?
    public var openSubsonic: Bool
    public var extensions: Set<String>

    /// "Navidrome 0.58.0"
    public var displayName: String {
        let name = type.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Subsonic server"
        guard let version else { return name }
        return "\(name) \(version.split(separator: " ").first.map(String.init) ?? version)"
    }
}

public struct SearchResults: Sendable {
    public var artists: [Artist]
    public var albums: [Album]
    public var tracks: [Track]
}

public final class SubsonicClient: Sendable {
    public static let clientName = "Discodrome"
    public static let apiVersion = "1.16.1"

    public let credentials: ServerCredentials
    private let session: URLSession

    public init(credentials: ServerCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: URLs

    public func endpointURL(_ endpoint: String, _ parameters: [(String, String)] = []) -> URL {
        var url = credentials.serverURL
        url.append(path: "rest/\(endpoint).view")
        let all = [
            ("u", credentials.username), ("t", credentials.token), ("s", credentials.salt),
            ("v", Self.apiVersion), ("c", Self.clientName), ("f", "json"),
        ] + parameters
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = all.map { "\(Self.escape($0.0))=\(Self.escape($0.1))" }.joined(separator: "&")
        return components.url!
    }

    /// Strict RFC 3986 escaping. URLComponents leaves "+" alone, which Go's query parser —
    /// and so Navidrome — reads back as a space.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func escape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// Original bytes where the Mac can decode them; otherwise let the server transcode.
    public func streamURL(id: String, format: String? = "raw", maxBitRate: Int? = nil) -> URL {
        var parameters = [("id", id)]
        if let format { parameters.append(("format", format)) }
        if let maxBitRate { parameters.append(("maxBitRate", String(maxBitRate))) }
        return endpointURL("stream", parameters)
    }

    public func downloadURL(id: String) -> URL {
        endpointURL("download", [("id", id)])
    }

    public func coverArtURL(id: String, size: Int?) -> URL {
        var parameters = [("id", id)]
        if let size { parameters.append(("size", String(size))) }
        return endpointURL("getCoverArt", parameters)
    }

    // MARK: Transport

    private func body<P: Decodable>(_ endpoint: String, _ parameters: [(String, String)], as: P.Type) async throws -> SubsonicBody<P> {
        var request = URLRequest(url: endpointURL(endpoint, parameters))
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubsonicError.http(http.statusCode)
        }
        let root: SubsonicRoot<P>
        do {
            root = try SubsonicDate.decoder().decode(SubsonicRoot<P>.self, from: data)
        } catch let error as DecodingError {
            throw SubsonicError.decoding(Self.describe(error))
        }
        if let error = root.body.error {
            throw SubsonicError.api(code: error.code, message: error.message ?? "The server reported an error.")
        }
        guard root.body.status == "ok" else {
            throw SubsonicError.api(code: 0, message: "The server answered with status “\(root.body.status)”.")
        }
        return root.body
    }

    private func get<P: Decodable>(_ endpoint: String, _ parameters: [(String, String)] = [], as type: P.Type) async throws -> P {
        guard let payload = try await body(endpoint, parameters, as: type).payload else {
            throw SubsonicError.decoding("empty \(endpoint) response")
        }
        return payload
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default:
            return String(describing: error)
        }
    }

    /// The error a server sent in place of a file, when `data` is a Subsonic error document.
    public static func apiError(in data: Data) -> SubsonicError? {
        guard let root = try? SubsonicDate.decoder().decode(SubsonicRoot<EmptyPayload>.self, from: data),
              let error = root.body.error else { return nil }
        return .api(code: error.code, message: error.message ?? "The server refused the request.")
    }

    // MARK: System

    public func ping() async throws -> ServerInfo {
        let body = try await body("ping", [], as: EmptyPayload.self)
        var info = ServerInfo(type: body.serverType, version: body.serverVersion, openSubsonic: body.openSubsonic ?? false, extensions: [])
        if info.openSubsonic, let payload = try? await get("getOpenSubsonicExtensions", as: ExtensionsPayload.self) {
            info.extensions = Set((payload.openSubsonicExtensions ?? []).map(\.name))
        }
        return info
    }

    // MARK: Browsing

    public func albumPage(type: String = "alphabeticalByName", size: Int = 500, offset: Int = 0) async throws -> [Album] {
        let payload = try await get("getAlbumList2", [("type", type), ("size", String(size)), ("offset", String(offset))], as: AlbumListPayload.self)
        return (payload.albumList2.album ?? []).map(\.album)
    }

    public func allAlbums(pageSize: Int = 500) async throws -> [Album] {
        var albums: [Album] = []
        while true {
            let page = try await albumPage(size: pageSize, offset: albums.count)
            albums += page
            if page.count < pageSize { return albums }
        }
    }

    public func album(id: String) async throws -> (album: Album, tracks: [Track]) {
        let dto = try await get("getAlbum", [("id", id)], as: AlbumPayload.self).album
        return (dto.album, (dto.song ?? []).map(\.track_))
    }

    public func artists() async throws -> [Artist] {
        let payload = try await get("getArtists", as: ArtistsPayload.self)
        return (payload.artists.index ?? []).flatMap { ($0.artist ?? []).map(\.artist) }
    }

    public func artist(id: String) async throws -> (artist: Artist, albums: [Album]) {
        let dto = try await get("getArtist", [("id", id)], as: ArtistPayload.self).artist
        return (dto.artist, (dto.album ?? []).map(\.album))
    }

    public func song(id: String) async throws -> Track {
        try await get("getSong", [("id", id)], as: SongPayload.self).song.track_
    }

    /// One page of every song on the server. Navidrome treats the query `""` as "match all",
    /// which is how offline-sync clients enumerate a library.
    public func songPage(offset: Int, count: Int, query: String = "\"\"") async throws -> [Track] {
        let payload = try await get("search3", [
            ("query", query), ("artistCount", "0"), ("albumCount", "0"),
            ("songCount", String(count)), ("songOffset", String(offset)),
        ], as: SearchPayload.self)
        return (payload.searchResult3.song ?? []).map(\.track_)
    }

    public func allSongs(pageSize: Int = 500, progress: @Sendable (Int) -> Void = { _ in }) async throws -> [Track] {
        var query = "\"\""
        var songs: [Track] = []
        while true {
            try Task.checkCancellation()
            var page = try await songPage(offset: songs.count, count: pageSize, query: query)
            if songs.isEmpty && page.isEmpty && query != "" {
                // Some servers want a genuinely empty query instead.
                query = ""
                page = try await songPage(offset: 0, count: pageSize, query: query)
            }
            songs += page
            progress(songs.count)
            if page.count < pageSize { return songs }
        }
    }

    public func search(_ text: String, artistCount: Int = 12, albumCount: Int = 30, songCount: Int = 100) async throws -> SearchResults {
        let payload = try await get("search3", [
            ("query", text), ("artistCount", String(artistCount)), ("albumCount", String(albumCount)), ("songCount", String(songCount)),
        ], as: SearchPayload.self)
        return SearchResults(
            artists: (payload.searchResult3.artist ?? []).map(\.artist),
            albums: (payload.searchResult3.album ?? []).map(\.album),
            tracks: (payload.searchResult3.song ?? []).map(\.track_)
        )
    }

    // MARK: Playlists

    public func playlists() async throws -> [Playlist] {
        (try await get("getPlaylists", as: PlaylistsPayload.self).playlists.playlist ?? []).map(\.playlist)
    }

    public func playlist(id: String) async throws -> (playlist: Playlist, tracks: [Track]) {
        let dto = try await get("getPlaylist", [("id", id)], as: PlaylistPayload.self).playlist
        return (dto.playlist, (dto.entry ?? []).map(\.track_))
    }

    public func createPlaylist(name: String, songIDs: [String]) async throws {
        _ = try await body("createPlaylist", [("name", name)] + songIDs.map { ("songId", $0) }, as: EmptyPayload.self)
    }

    public func addToPlaylist(id: String, songIDs: [String]) async throws {
        _ = try await body("updatePlaylist", [("playlistId", id)] + songIDs.map { ("songIdToAdd", $0) }, as: EmptyPayload.self)
    }

    // MARK: Lyrics & scrobbling

    /// Best lyrics the server has: synced structured lyrics when the songLyrics extension is
    /// available, then the classic endpoint (whose text is sometimes LRC in disguise).
    public func lyrics(for track: Track, structured: Bool) async throws -> Lyrics? {
        if structured {
            let list = try await get("getLyricsBySongId", [("id", track.id)], as: LyricsListPayload.self)
            let all = (list.lyricsList.structuredLyrics ?? []).map(\.lyrics).filter { !$0.lines.isEmpty }
            if let best = all.first(where: \.synced) ?? all.first { return best }
        }
        let legacy = try await get("getLyrics", [("artist", track.artist), ("title", track.title)], as: LegacyLyricsPayload.self)
        guard let text = legacy.lyrics?.value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LRCParser.parse(text)
    }

    /// `submission: false` announces "now playing"; `true` counts a play.
    public func scrobble(id: String, submission: Bool, at date: Date = Date()) async throws {
        _ = try await body("scrobble", [
            ("id", id), ("submission", submission ? "true" : "false"),
            ("time", String(Int64(date.timeIntervalSince1970 * 1000))),
        ], as: EmptyPayload.self)
    }
}
