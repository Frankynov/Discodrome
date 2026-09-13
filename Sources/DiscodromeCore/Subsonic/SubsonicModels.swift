import Foundation

// Wire formats for the (Open)Subsonic JSON API. Only this file knows their shape; everything
// else works with the public models in LibraryModels.swift.

struct SubsonicRoot<Payload: Decodable>: Decodable {
    let body: SubsonicBody<Payload>
    enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
}

struct SubsonicBody<Payload: Decodable>: Decodable {
    let status: String
    let error: ErrorDTO?
    let serverType: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let payload: Payload?

    enum CodingKeys: String, CodingKey { case status, error, type, serverVersion, openSubsonic }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        error = try c.decodeIfPresent(ErrorDTO.self, forKey: .error)
        serverType = try c.decodeIfPresent(String.self, forKey: .type)
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion)
        openSubsonic = try c.decodeIfPresent(Bool.self, forKey: .openSubsonic)
        // The payload sits next to `status` in the same object, under an endpoint-specific key.
        payload = status == "ok" ? try Payload(from: decoder) : nil
    }
}

struct ErrorDTO: Decodable {
    let code: Int
    let message: String?
}

struct EmptyPayload: Decodable {}

struct NameDTO: Decodable {
    let id: String?
    let name: String
}

struct ChildDTO: Decodable {
    let id: String
    let isDir: Bool?
    let title: String?
    let album: String?
    let artist: String?
    let track: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let size: Int64?
    let contentType: String?
    let suffix: String?
    let duration: Int?
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    let path: String?
    let discNumber: Int?
    let created: Date?
    let albumId: String?
    let artistId: String?
    let playCount: Int?
    let starred: Date?
    let musicBrainzId: String?
    let displayAlbumArtist: String?
    let albumArtists: [NameDTO]?

    var track_: Track {
        let artistName = (artist?.isEmpty == false ? artist : nil) ?? "Unknown Artist"
        let albumArtistName = (displayAlbumArtist?.isEmpty == false ? displayAlbumArtist : nil)
            ?? albumArtists.flatMap { $0.isEmpty ? nil : $0.map(\.name).joined(separator: ", ") }
            ?? artistName
        let ext = suffix ?? path.map { ($0 as NSString).pathExtension } ?? ""
        return Track(
            id: id, origin: .server, title: title ?? "Untitled", artist: artistName,
            albumArtist: albumArtistName, album: album ?? "Unknown Album", albumID: albumId, artistID: artistId,
            trackNumber: track, discNumber: discNumber, year: year, genre: genre,
            duration: TimeInterval(duration ?? 0), bitRate: bitRate, sampleRate: samplingRate,
            bitDepth: bitDepth, channels: channelCount, size: size, suffix: ext, contentType: contentType,
            coverArtID: coverArt, path: path, created: created, playCount: playCount, starred: starred,
            musicBrainzID: musicBrainzId
        )
    }
}

struct AlbumDTO: Decodable {
    let id: String
    let name: String?
    let title: String?
    let artist: String?
    let displayArtist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let created: Date?
    let playCount: Int?
    let starred: Date?
    let isCompilation: Bool?
    let song: [ChildDTO]?

    var album: Album {
        Album(
            id: id, name: name ?? title ?? "Unknown Album",
            artist: (displayArtist?.isEmpty == false ? displayArtist : nil) ?? artist ?? "Unknown Artist",
            artistID: artistId, coverArtID: coverArt, songCount: songCount ?? song?.count ?? 0,
            duration: TimeInterval(duration ?? 0), year: year, genre: genre, created: created,
            playCount: playCount, starred: starred, isCompilation: isCompilation ?? false
        )
    }
}

struct ArtistDTO: Decodable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let album: [AlbumDTO]?

    var artist: Artist { Artist(id: id, name: name, albumCount: albumCount ?? album?.count ?? 0, coverArtID: coverArt) }
}

struct PlaylistDTO: Decodable {
    let id: String
    let name: String
    let comment: String?
    let owner: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let changed: Date?
    let entry: [ChildDTO]?

    var playlist: Playlist {
        Playlist(
            id: id, name: name, comment: comment, owner: owner, songCount: songCount ?? entry?.count ?? 0,
            duration: TimeInterval(duration ?? 0), coverArtID: coverArt, changed: changed
        )
    }
}

struct StructuredLyricsDTO: Decodable {
    struct LineDTO: Decodable {
        let start: Int?
        let value: String
    }
    let lang: String?
    let synced: Bool
    let offset: Int?
    let line: [LineDTO]?

    var lyrics: Lyrics {
        let shift = TimeInterval(offset ?? 0) / 1000
        return Lyrics(
            synced: synced,
            lines: (line ?? []).map { Lyrics.Line(start: synced ? $0.start.map { max(0, TimeInterval($0) / 1000 + shift) } : nil, text: $0.value) },
            language: lang
        )
    }
}

// MARK: Endpoint payloads

struct AlbumListPayload: Decodable {
    struct List: Decodable { let album: [AlbumDTO]? }
    let albumList2: List
}

struct AlbumPayload: Decodable { let album: AlbumDTO }

struct ArtistsPayload: Decodable {
    struct Index: Decodable { let artist: [ArtistDTO]? }
    struct Artists: Decodable { let index: [Index]? }
    let artists: Artists
}

struct ArtistPayload: Decodable { let artist: ArtistDTO }

struct SearchPayload: Decodable {
    struct Result: Decodable {
        let artist: [ArtistDTO]?
        let album: [AlbumDTO]?
        let song: [ChildDTO]?
    }
    let searchResult3: Result
}

struct PlaylistsPayload: Decodable {
    struct Playlists: Decodable { let playlist: [PlaylistDTO]? }
    let playlists: Playlists
}

struct PlaylistPayload: Decodable { let playlist: PlaylistDTO }

struct SongPayload: Decodable { let song: ChildDTO }

struct LyricsListPayload: Decodable {
    struct List: Decodable { let structuredLyrics: [StructuredLyricsDTO]? }
    let lyricsList: List
}

struct LegacyLyricsPayload: Decodable {
    struct Body: Decodable { let value: String? }
    let lyrics: Body?
}

struct ExtensionsPayload: Decodable {
    struct Ext: Decodable { let name: String; let versions: [Int]? }
    let openSubsonicExtensions: [Ext]?
}

// MARK: Dates

enum SubsonicDate {
    // ISO8601DateFormatter is documented as thread-safe once configured.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Navidrome sends nanosecond fractions ("…:33.123456789Z"), which the formatter rejects;
    /// trim them to milliseconds first.
    static func parse(_ string: String) -> Date? {
        if let date = whole.date(from: string) { return date }
        var s = string
        if let dot = s.firstIndex(of: ".") {
            let digitsEnd = s[s.index(after: dot)...].firstIndex { !$0.isNumber } ?? s.endIndex
            let digits = s[s.index(after: dot)..<digitsEnd]
            if digits.count > 3 {
                s.replaceSubrange(s.index(after: dot)..<digitsEnd, with: digits.prefix(3))
            }
        }
        return fractional.date(from: s) ?? whole.date(from: s)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleContainer().decode(String.self)
            guard let date = parse(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unreadable date \(raw)"))
            }
            return date
        }
        return decoder
    }
}

private extension Decoder {
    func singleContainer() throws -> SingleValueDecodingContainer { try singleValueContainer() }
}
