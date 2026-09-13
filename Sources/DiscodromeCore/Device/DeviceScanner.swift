import Darwin
import Foundation

/// How the card's space is used, in the categories the capacity bar draws.
public struct DeviceUsage: Codable, Hashable, Sendable {
    public var capacity: Int64
    public var available: Int64
    public var hiRes: Int64 = 0
    public var lossless: Int64 = 0
    public var lossy: Int64 = 0
    public var lyricsAndArt: Int64 = 0

    public init(capacity: Int64, available: Int64) {
        self.capacity = capacity
        self.available = available
    }

    public var used: Int64 { max(0, capacity - available) }
    /// Everything that isn't music: other files, filesystem overhead.
    public var other: Int64 { max(0, used - hiRes - lossless - lossy - lyricsAndArt) }
}

public struct DeviceScanResult: Sendable {
    public var files: [DeviceFile]
    public var usage: DeviceUsage
    /// AppleDouble `._` files and `.DS_Store` that macOS leaves on FAT cards. Players list
    /// the `._` ones as broken tracks.
    public var clutter: [String]
}

public enum DeviceScanner {
    static let skippedFolders: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", "System Volume Information", "$RECYCLE.BIN",
    ]
    static let sidecarExtensions: Set<String> = ["lrc", "jpg", "jpeg", "png", "cue", "m3u", "m3u8"]

    /// Walks the volume. Files whose size and date match `known` reuse the tags already read,
    /// which keeps rescans of a large card to a directory walk.
    public static func scan(
        root: URL,
        known: [String: DeviceFile],
        capacity: Int64,
        available: Int64,
        progress: (Int) -> Void = { _ in }
    ) -> DeviceScanResult {
        var files: [DeviceFile] = []
        var clutter: [String] = []
        var usage = DeviceUsage(capacity: capacity, available: available)
        let rootPath = root.standardizedFileURL.path

        DirectoryWalker.walk(rootPath, skipping: skippedFolders) { entry in
            let relative = String(entry.path.dropFirst(rootPath.count).drop { $0 == "/" })
            let name = entry.name
            if name.hasPrefix("._") || name == ".DS_Store" {
                clutter.append(relative)
                return
            }
            let ext = (name as NSString).pathExtension.lowercased()
            if sidecarExtensions.contains(ext) {
                usage.lyricsAndArt += entry.size
                return
            }
            guard AudioTagReader.audioExtensions.contains(ext), !name.hasPrefix(".") else { return }

            var file: DeviceFile
            if let cached = known[relative], cached.size == entry.size, abs(cached.modified.timeIntervalSince(entry.modified)) < 2.5 {
                file = cached
            } else {
                var info = AudioTagReader.read(URL(fileURLWithPath: entry.path)) ?? AudioFileInfo()
                fillGaps(&info, relativePath: relative)
                // A file that changed since we recorded it is no longer the copy we made.
                file = DeviceFile(relativePath: relative, size: entry.size, modified: entry.modified, info: info, sourceTrackID: nil)
            }
            let track = file.track(volumeRoot: root)
            if track.isHiRes { usage.hiRes += entry.size } else if track.isLossless { usage.lossless += entry.size } else { usage.lossy += entry.size }
            files.append(file)
            if files.count % 50 == 0 { progress(files.count) }
        }
        progress(files.count)
        return DeviceScanResult(files: files, usage: usage, clutter: clutter)
    }

    private static let genericFolders: Set<String> = ["music", "musique", "musik", "música", "audio", "songs", "mp3"]

    /// Untagged files still deserve a name: "Artist/Album/03 Title.flac" says a lot.
    static func fillGaps(_ info: inout AudioFileInfo, relativePath: String) {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let fileName = parts.last else { return }
        var stem = (fileName as NSString).deletingPathExtension

        let digits = stem.prefix { $0.isASCII && $0.isNumber }
        if (1...3).contains(digits.count) {
            let rest = stem.dropFirst(digits.count)
            if let first = rest.first, first == " " || first == "." || first == "-" || first == "_" {
                if info.trackNumber == nil { info.trackNumber = Int(digits) }
                stem = String(rest.drop { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            }
        }
        if info.title == nil { info.title = stem.isEmpty ? fileName : stem }

        let folders = parts.dropLast().filter { !genericFolders.contains($0.lowercased()) }
        if info.album == nil, let album = folders.last { info.album = album }
        if info.artist == nil, folders.count >= 2 { info.artist = folders[folders.count - 2] }
        if info.albumArtist == nil { info.albumArtist = info.artist }
    }

    /// Deletes the AppleDouble and Finder files found by a scan. Returns how many went.
    public static func removeClutter(_ paths: [String], root: URL) -> Int {
        var removed = 0
        for path in paths {
            let url = root.appending(path: path)
            // Only ever these two kinds of file, whatever the list says.
            let name = url.lastPathComponent
            guard name.hasPrefix("._") || name == ".DS_Store" else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

/// macOS attaches extended attributes — `com.apple.provenance`, at least — to files and folders
/// an app creates. FAT and exFAT can't hold them, so macOS writes a `._name` file beside each,
/// which the SNOWSKY DISC lists as a broken song. Deleting that twin once the file is complete
/// discards the attributes with it, as `dot_clean` does.
public enum AppleDouble {
    /// Deletes the `._` twins of `url` and of each folder above it, up to but excluding `root`.
    @discardableResult
    public static func removeTwins(of url: URL, upTo root: URL) -> Int {
        let rootPath = root.standardizedFileURL.path
        var current = url.standardizedFileURL
        var removed = 0
        while current.path.count > rootPath.count, current.path.hasPrefix(rootPath) {
            let twin = current.deletingLastPathComponent().path + "/._" + current.lastPathComponent
            var status = stat()
            if lstat(twin, &status) == 0, status.st_mode & S_IFMT == S_IFREG, unlink(twin) == 0 {
                removed += 1
            }
            current = current.deletingLastPathComponent()
        }
        return removed
    }
}

/// Walks a directory tree with readdir(3). Foundation's enumerators leave out AppleDouble `._`
/// files — exactly the debris a scan of a memory card needs to find.
enum DirectoryWalker {
    struct Entry {
        let path: String
        let name: String
        let size: Int64
        let modified: Date
    }

    /// Calls `visit` for every regular file below `root`, not descending into `skipping`.
    static func walk(_ root: String, skipping: Set<String>, visit: (Entry) -> Void) {
        var pending = [root]
        while let directory = pending.popLast() {
            guard let handle = opendir(directory) else { continue }
            defer { closedir(handle) }
            while let pointer = readdir(handle) {
                let length = Int(pointer.pointee.d_namlen)
                let name = withUnsafeBytes(of: pointer.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
                guard name != ".", name != ".." else { continue }
                let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
                var status = stat()
                guard lstat(path, &status) == 0 else { continue }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    if !skipping.contains(name) { pending.append(path) }
                case S_IFREG:
                    let seconds = TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
                    visit(Entry(path: path, name: name, size: Int64(status.st_size), modified: Date(timeIntervalSince1970: seconds)))
                default:
                    break
                }
            }
        }
    }
}

extension DeviceFile {
    /// The file as a playable, listable track.
    public func track(volumeRoot: URL) -> Track {
        let stem = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return Track(
            id: "device:" + relativePath,
            origin: .file(volumeRoot.appending(path: relativePath)),
            title: info.title ?? stem,
            artist: info.artist ?? "Unknown Artist",
            albumArtist: info.albumArtist ?? info.artist ?? "Unknown Artist",
            album: info.album ?? "Unknown Album",
            trackNumber: info.trackNumber, discNumber: info.discNumber, year: info.year, genre: info.genre,
            duration: info.duration ?? 0, bitRate: info.bitRate, sampleRate: info.sampleRate,
            bitDepth: info.codec == "aac" ? nil : info.bitDepth, channels: info.channels, size: size, suffix: suffix,
            contentType: info.codec == "alac" ? "audio/alac" : nil, path: relativePath,
            musicBrainzID: info.musicBrainzTrackID
        )
    }
}
