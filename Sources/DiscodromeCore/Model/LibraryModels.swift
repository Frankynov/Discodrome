import Foundation

/// One playable song, whichever source it comes from — the Navidrome server or a file on a
/// mounted device. The UI, the player and the transfer queue all speak `Track`.
public struct Track: Codable, Hashable, Sendable, Identifiable {
    public enum Origin: Codable, Hashable, Sendable {
        case server
        case file(URL)
    }

    public var id: String
    public var origin: Origin
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var albumID: String?
    public var artistID: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    /// Seconds.
    public var duration: TimeInterval
    /// Kilobits per second.
    public var bitRate: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var size: Int64?
    /// Lower-case file extension without the dot, e.g. `flac`.
    public var suffix: String
    public var contentType: String?
    public var coverArtID: String?
    /// Path relative to the server's music folder, as Navidrome reports it.
    public var path: String?
    public var created: Date?
    public var playCount: Int?
    public var starred: Date?
    public var musicBrainzID: String?

    public init(
        id: String, origin: Origin, title: String, artist: String, albumArtist: String, album: String,
        albumID: String? = nil, artistID: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
        year: Int? = nil, genre: String? = nil, duration: TimeInterval = 0, bitRate: Int? = nil,
        sampleRate: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil, size: Int64? = nil,
        suffix: String, contentType: String? = nil, coverArtID: String? = nil, path: String? = nil,
        created: Date? = nil, playCount: Int? = nil, starred: Date? = nil, musicBrainzID: String? = nil
    ) {
        self.id = id; self.origin = origin; self.title = title; self.artist = artist
        self.albumArtist = albumArtist; self.album = album; self.albumID = albumID; self.artistID = artistID
        self.trackNumber = trackNumber; self.discNumber = discNumber; self.year = year; self.genre = genre
        self.duration = duration; self.bitRate = bitRate; self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.channels = channels; self.size = size; self.suffix = suffix.lowercased(); self.contentType = contentType
        self.coverArtID = coverArtID; self.path = path; self.created = created; self.playCount = playCount
        self.starred = starred; self.musicBrainzID = musicBrainzID
    }

    public var isServerTrack: Bool { origin == .server }

    public var fileURL: URL? {
        if case .file(let url) = origin { return url }
        return nil
    }
}

// MARK: - Format

extension Track {
    public var isLossless: Bool {
        switch suffix {
        case "flac", "wav", "aif", "aiff", "aifc", "ape", "wv", "alac", "dsf", "dff", "caf": return true
        case "m4a", "mp4": return (bitDepth ?? 0) > 0 || (contentType?.contains("alac") ?? false)
        default: return false
        }
    }

    public var isDSD: Bool { suffix == "dsf" || suffix == "dff" }

    /// Anything beyond CD resolution: more than 48 kHz, more than 16 bits, or DSD.
    public var isHiRes: Bool {
        isDSD || (isLossless && ((sampleRate ?? 0) > 48_000 || (bitDepth ?? 0) > 16))
    }

    public var codecName: String {
        switch suffix {
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "m4a", "mp4", "aac": return isLossless ? "ALAC" : "AAC"
        case "alac": return "ALAC"
        case "wav": return "WAV"
        case "aif", "aiff", "aifc": return "AIFF"
        case "ape": return "APE"
        case "wv": return "WavPack"
        case "ogg", "oga": return "Vorbis"
        case "opus": return "Opus"
        case "dsf", "dff": return "DSD"
        case "wma": return "WMA"
        default: return suffix.uppercased()
        }
    }

    /// "FLAC 24/96", "MP3 320 kbps", "DSD 2.8 MHz".
    public var formatLabel: String {
        if isDSD, let rate = sampleRate, rate > 0 {
            return "DSD\(rate / 44_100)"
        }
        if isLossless, let bits = bitDepth, bits > 0, let rate = sampleRate, rate > 0 {
            return "\(codecName) \(bits)/\(Track.kilohertz(rate))"
        }
        if let rate = bitRate, rate > 0 { return "\(codecName) \(rate) kbps" }
        return codecName
    }

    public static func kilohertz(_ rate: Int) -> String {
        let k = Double(rate) / 1000
        return k.rounded() == k ? String(Int(k)) : String(format: "%.1f", k)
    }
}

public struct Album: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var artist: String
    public var artistID: String?
    public var coverArtID: String?
    public var songCount: Int
    public var duration: TimeInterval
    public var year: Int?
    public var genre: String?
    public var created: Date?
    public var playCount: Int?
    public var starred: Date?
    public var isCompilation: Bool

    public init(
        id: String, name: String, artist: String, artistID: String? = nil, coverArtID: String? = nil,
        songCount: Int = 0, duration: TimeInterval = 0, year: Int? = nil, genre: String? = nil,
        created: Date? = nil, playCount: Int? = nil, starred: Date? = nil, isCompilation: Bool = false
    ) {
        self.id = id; self.name = name; self.artist = artist; self.artistID = artistID
        self.coverArtID = coverArtID; self.songCount = songCount; self.duration = duration; self.year = year
        self.genre = genre; self.created = created; self.playCount = playCount; self.starred = starred
        self.isCompilation = isCompilation
    }
}

public struct Artist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var albumCount: Int
    public var coverArtID: String?

    public init(id: String, name: String, albumCount: Int = 0, coverArtID: String? = nil) {
        self.id = id; self.name = name; self.albumCount = albumCount; self.coverArtID = coverArtID
    }
}

public struct Playlist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var comment: String?
    public var owner: String?
    public var songCount: Int
    public var duration: TimeInterval
    public var coverArtID: String?
    public var changed: Date?

    public init(
        id: String, name: String, comment: String? = nil, owner: String? = nil, songCount: Int = 0,
        duration: TimeInterval = 0, coverArtID: String? = nil, changed: Date? = nil
    ) {
        self.id = id; self.name = name; self.comment = comment; self.owner = owner
        self.songCount = songCount; self.duration = duration; self.coverArtID = coverArtID; self.changed = changed
    }
}

public struct Lyrics: Codable, Hashable, Sendable {
    public struct Line: Codable, Hashable, Sendable {
        /// Seconds from the start of the track; nil for unsynced lyrics.
        public var start: TimeInterval?
        public var text: String
        public init(start: TimeInterval?, text: String) { self.start = start; self.text = text }
    }

    public var synced: Bool
    public var lines: [Line]
    public var language: String?

    public init(synced: Bool, lines: [Line], language: String? = nil) {
        self.synced = synced; self.lines = lines; self.language = language
    }

    /// Index of the line being sung at `time`, for synced lyrics.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard synced else { return nil }
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if (lines[mid].start ?? 0) <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// The `.lrc` text the SNOWSKY DISC reads from a sidecar file next to the track.
    public func lrcText(title: String, artist: String, album: String) -> String? {
        guard synced else { return nil }
        var out = "[ti:\(title)]\n[ar:\(artist)]\n[al:\(album)]\n"
        for line in lines {
            guard let start = line.start else { continue }
            let centis = Int((start * 100).rounded())
            out += String(format: "[%02d:%02d.%02d]", centis / 6000, (centis / 100) % 60, centis % 100) + line.text + "\n"
        }
        return out
    }
}
