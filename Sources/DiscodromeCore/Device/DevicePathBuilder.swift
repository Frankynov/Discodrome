import Foundation

/// Decides where a song lands on the device's card. The SNOWSKY DISC has no playlists, so
/// people browse it by folder — the layout is the interface.
public struct DevicePathBuilder: Sendable, Equatable {
    public static let defaultTemplate = "{albumartist}/{album}/{disc}{track} {title}"

    /// Folder at the card root that holds the music, e.g. "Music". Empty means the root.
    public var musicFolder: String
    /// Tokens: {albumartist} {artist} {album} {year} {genre} {disc} {track} {title}.
    /// `{disc}` becomes "2-" only for multi-disc albums; `{track}` is zero-padded.
    public var template: String

    public init(musicFolder: String = "Music", template: String = DevicePathBuilder.defaultTemplate) {
        self.musicFolder = musicFolder
        self.template = template
    }

    /// Relative path (with `/` separators) for `track` stored with the extension `suffix`.
    public func relativePath(for track: Track, suffix: String, discCount: Int? = nil) -> String {
        let multiDisc = (discCount ?? 1) > 1 || (track.discNumber ?? 1) > 1
        let values: [String: String] = [
            "albumartist": track.albumArtist,
            "artist": track.artist,
            "album": track.album,
            "year": track.year.map(String.init) ?? "",
            "genre": track.genre ?? "",
            "disc": multiDisc ? "\(track.discNumber ?? 1)-" : "",
            "track": track.trackNumber.map { String(format: "%02d", $0) } ?? "",
            "title": track.title,
        ]

        // Substitute per path component, so a "/" inside a value can't create folders.
        let templateComponents = template.split(separator: "/", omittingEmptySubsequences: true)
        var components: [String] = []
        for (index, raw) in templateComponents.enumerated() {
            var text = String(raw)
            for (key, value) in values {
                text = text.replacingOccurrences(of: "{\(key)}", with: Self.sanitizeValue(value))
            }
            let isFile = index == templateComponents.count - 1
            text = text.trimmingCharacters(in: .whitespaces)
            if isFile {
                // "{disc}{track} {title}" with no track number would leave "- Title" or " Title".
                while let first = text.first, first == "-" || first == " " { text.removeFirst() }
                if text.isEmpty { text = Self.sanitizeValue(track.title) }
                components.append(Self.sanitizeComponent(text, maxLength: 120 - suffix.count - 1) + "." + suffix.lowercased())
            } else {
                components.append(Self.sanitizeComponent(text.isEmpty ? "Unknown" : text, maxLength: 100))
            }
        }

        let folder = musicFolder
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { Self.sanitizeComponent(String($0), maxLength: 100) }
        return (folder + components).joined(separator: "/")
    }

    /// Field values can't carry path separators or FAT-forbidden characters.
    static func sanitizeValue(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "/", "\\": out += "-"
            case ":": out += " -"
            case "\"": out += "'"
            case "*", "?", "<", ">", "|": out += "_"
            default:
                if character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) { out.append(character) }
            }
        }
        return out.replacingOccurrences(of: "  ", with: " ")
    }

    private static let reservedNames: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    ]

    /// One FAT32/exFAT-legal file or folder name: NFC, no forbidden characters, no leading
    /// dot, no trailing dot or space, no DOS device names, bounded length.
    public static func sanitizeComponent(_ name: String, maxLength: Int = 100) -> String {
        var text = sanitizeValue(name).precomposedStringWithCanonicalMapping
        text = text.trimmingCharacters(in: .whitespaces)
        if text.count > maxLength { text = String(text.prefix(maxLength)) }
        while let last = text.last, last == "." || last == " " { text.removeLast() }
        if text.hasPrefix(".") { text = "_" + text.dropFirst() }
        if text.isEmpty { text = "_" }
        if reservedNames.contains(text.lowercased()) { text += "_" }
        return text
    }
}
