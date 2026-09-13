import Foundation

/// An audio file found on the device's card.
public struct DeviceFile: Codable, Hashable, Sendable, Identifiable {
    /// Path from the volume root, with `/` separators.
    public var relativePath: String
    public var size: Int64
    public var modified: Date
    /// Tags, with gaps filled from the folder layout (see `DeviceScanner`).
    public var info: AudioFileInfo
    /// The server song this file was copied from, when Discodrome put it there.
    public var sourceTrackID: String?

    public var id: String { relativePath }

    public init(relativePath: String, size: Int64, modified: Date, info: AudioFileInfo, sourceTrackID: String? = nil) {
        self.relativePath = relativePath; self.size = size; self.modified = modified
        self.info = info; self.sourceTrackID = sourceTrackID
    }

    public var suffix: String { (relativePath as NSString).pathExtension.lowercased() }
}

/// Where a library song already lives on the device.
public enum DevicePresence: Hashable, Sendable {
    /// Copied by Discodrome, or byte-for-byte the same size with the same title.
    case exact(String)
    /// Same song by its tags — likely a copy made another way, or a different encode.
    case likely(String)

    public var relativePath: String {
        switch self {
        case .exact(let path), .likely(let path): return path
        }
    }

    public var isExact: Bool {
        if case .exact = self { return true }
        return false
    }
}

public enum DeviceMatcher {
    public struct Result: Sendable {
        /// Library track id → where it is on the device.
        public var presence: [String: DevicePresence] = [:]
        /// Device relative path → the library track it corresponds to.
        public var trackForFile: [String: String] = [:]

        public init() {}
    }

    /// Titles often carry "(Remastered 2011)" or "[feat. X]" on one side only; for the loose
    /// pass those brackets and featuring credits don't count.
    static func looseTitle(_ title: String) -> String {
        var text = ""
        var depth = 0
        for character in title {
            if character == "(" || character == "[" { depth += 1; continue }
            if character == ")" || character == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { text.append(character) }
        }
        let key = text.matchKey
        for marker in [" feat ", " ft ", " featuring "] {
            if let range = key.range(of: marker) { return String(key[..<range.lowerBound]) }
        }
        return key
    }

    static func albumKey(_ albumArtist: String?, _ album: String?, _ disc: Int?, _ track: Int) -> String {
        "\((albumArtist ?? "").matchKey)|\((album ?? "").matchKey)|\(max(disc ?? 1, 1))|\(track)"
    }

    static func songKey(_ artist: String?, _ title: String?) -> String {
        "\((artist ?? "").matchKey)|\(looseTitle(title ?? ""))"
    }

    static func durationsAgree(_ a: TimeInterval?, _ b: TimeInterval?, tolerance: TimeInterval) -> Bool {
        guard let a, let b, a > 0, b > 0 else { return true }
        return abs(a - b) <= tolerance
    }

    public static func match(library: [Track], device files: [DeviceFile]) -> Result {
        var bySource: [String: DeviceFile] = [:]
        var bySizeAndTitle: [String: DeviceFile] = [:]
        var byAlbumPosition: [String: [DeviceFile]] = [:]
        var bySong: [String: [DeviceFile]] = [:]

        for file in files {
            if let id = file.sourceTrackID { bySource[id] = file }
            bySizeAndTitle["\(file.size)|\((file.info.title ?? "").matchKey)"] = file
            if let number = file.info.trackNumber {
                byAlbumPosition[albumKey(file.info.albumArtist ?? file.info.artist, file.info.album, file.info.discNumber, number), default: []].append(file)
                if let artist = file.info.artist, artist != file.info.albumArtist {
                    byAlbumPosition[albumKey(artist, file.info.album, file.info.discNumber, number), default: []].append(file)
                }
            }
            bySong[songKey(file.info.artist, file.info.title), default: []].append(file)
            if let albumArtist = file.info.albumArtist, albumArtist != file.info.artist {
                bySong[songKey(albumArtist, file.info.title), default: []].append(file)
            }
        }

        var result = Result()
        func record(_ track: Track, _ file: DeviceFile, exact: Bool) {
            result.presence[track.id] = exact ? .exact(file.relativePath) : .likely(file.relativePath)
            if result.trackForFile[file.relativePath] == nil || exact {
                result.trackForFile[file.relativePath] = track.id
            }
        }

        for track in library {
            // Recorded copies are trusted even if the server's file has since been re-tagged:
            // the scanner forgets the record as soon as the file on the card changes.
            if let file = bySource[track.id] {
                record(track, file, exact: true)
            } else if let size = track.size, let file = bySizeAndTitle["\(size)|\(track.title.matchKey)"] {
                record(track, file, exact: true)
            } else if let number = track.trackNumber,
                      let file = byAlbumPosition[albumKey(track.albumArtist, track.album, track.discNumber, number)]?.first(where: {
                          looseTitle($0.info.title ?? "") == looseTitle(track.title) && durationsAgree($0.info.duration, track.duration, tolerance: 3)
                      }) {
                record(track, file, exact: false)
            } else if let file = bySong[songKey(track.artist, track.title)]?.first(where: {
                durationsAgree($0.info.duration, track.duration, tolerance: 2)
            }) {
                record(track, file, exact: false)
            }
        }
        return result
    }
}
