import Foundation
import Testing
@testable import DiscodromeCore

struct TagReaderTests {
    static func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
    static func be32(_ value: Int) -> [UInt8] { (0..<4).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) } }
    static func syncsafe(_ value: Int) -> [UInt8] { [21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) } }

    func temporaryFile(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "discodrome-\(UUID().uuidString)-\(name)")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func readsFLACStreamInfoAndVorbisComments() throws {
        let rate = 96_000, channels = 2, bits = 24, samples = 96_000 * 10
        var streamInfo = [UInt8](repeating: 0, count: 34)
        streamInfo[10] = UInt8((rate >> 12) & 0xFF)
        streamInfo[11] = UInt8((rate >> 4) & 0xFF)
        streamInfo[12] = UInt8((rate & 0x0F) << 4 | (channels - 1) << 1 | (bits - 1) >> 4)
        streamInfo[13] = UInt8(((bits - 1) & 0x0F) << 4 | (samples >> 32) & 0x0F)
        streamInfo.replaceSubrange(14..<18, with: Self.be32(samples & 0xFFFF_FFFF))

        let entries = ["TITLE=Tide", "ARTIST=Glass Rivers", "ALBUMARTIST=Glass Rivers", "ALBUM=Northbound",
                       "TRACKNUMBER=1/9", "DATE=2021-05-01", "MUSICBRAINZ_TRACKID=abc-123"]
        var comments = Self.le32(4) + Array("test".utf8) + Self.le32(entries.count)
        for entry in entries { comments += Self.le32(entry.utf8.count) + Array(entry.utf8) }

        var file = Array("fLaC".utf8)
        file += [0x00] + Self.be32(34).dropFirst() + streamInfo            // STREAMINFO
        file += [0x06] + Self.be32(8).dropFirst() + [UInt8](repeating: 1, count: 8) // PICTURE
        file += [0x84] + Self.be32(comments.count).dropFirst() + comments   // VORBIS_COMMENT, last
        file += [UInt8](repeating: 0, count: 1000)

        let info = try #require(AudioTagReader.read(try temporaryFile("t.flac", file)))
        #expect(info.sampleRate == 96_000)
        #expect(info.channels == 2)
        #expect(info.bitDepth == 24)
        #expect(info.duration == 10)
        #expect(info.title == "Tide")
        #expect(info.albumArtist == "Glass Rivers")
        #expect(info.trackNumber == 1)
        #expect(info.year == 2021)
        #expect(info.musicBrainzTrackID == "abc-123")
        #expect(info.hasEmbeddedArt)
    }

    @Test func readsID3v23AndXingDuration() throws {
        func frame(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + Self.be32(body.count) + [0, 0] + body }
        let utf16Title: [UInt8] = [0x01, 0xFF, 0xFE] + Array("Tïde".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let frames = frame("TIT2", utf16Title)
            + frame("TPE1", [0x00] + Array("Glass Rivers".utf8))
            + frame("TRCK", [0x00] + Array("2/9".utf8))
            + frame("TCON", [0x00] + Array("(17)".utf8))
            + frame("APIC", [0x00] + [UInt8](repeating: 7, count: 300))
        let tag = Array("ID3".utf8) + [3, 0, 0] + Self.syncsafe(frames.count + 64) + frames + [UInt8](repeating: 0, count: 64)

        // MPEG-1 Layer III, 128 kbps, 44.1 kHz, joint stereo; a Xing header announcing 100 frames.
        var mpeg = [UInt8](repeating: 0, count: 417 * 2)
        mpeg.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0x64])
        mpeg.replaceSubrange(36..<48, with: Array("Xing".utf8) + Self.be32(1) + Self.be32(100))
        mpeg.replaceSubrange(417..<421, with: [0xFF, 0xFB, 0x90, 0x64])

        let info = try #require(AudioTagReader.read(try temporaryFile("t.mp3", tag + mpeg)))
        #expect(info.title == "Tïde")
        #expect(info.artist == "Glass Rivers")
        #expect(info.trackNumber == 2)
        #expect(info.genre == "Rock")
        #expect(info.sampleRate == 44_100)
        #expect(info.hasEmbeddedArt)
        let duration = try #require(info.duration)
        #expect(abs(duration - 100.0 * 1152 / 44_100) < 0.001)
    }

    @Test func readsM4AFromAfconvert() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "discodrome-m4a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = directory.appending(path: "tone.wav")
        try GaplessTests.writeTone(to: wav, frames: 88_200, offset: 0, rate: 44_100, settings: [
            AVFormatIDKeyName: kAudioFormatLinearPCMValue, "AVLinearPCMBitDepthKey": 16,
        ])
        for (codec, expected) in [("alac", "alac"), ("aac", "aac")] {
            let output = directory.appending(path: "tone-\(codec).m4a")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "m4af", "-d", codec, wav.path, output.path]
            try process.run()
            process.waitUntilExit()
            let info = try #require(AudioTagReader.read(output))
            #expect(info.codec == expected)
            #expect(info.sampleRate == 44_100)
            #expect(info.channels == 2)
            #expect(abs((info.duration ?? 0) - 2) < 0.1)
        }
    }

    @Test func fillsGapsFromTheFolderLayout() {
        var info = AudioFileInfo()
        DeviceScanner.fillGaps(&info, relativePath: "Music/Glass Rivers/Northbound/07 - Harbour Lights.flac")
        #expect(info.title == "Harbour Lights")
        #expect(info.trackNumber == 7)
        #expect(info.album == "Northbound")
        #expect(info.artist == "Glass Rivers")
    }
}

struct MatcherTests {
    func libraryTrack(_ id: String, _ title: String, number: Int?, duration: TimeInterval, size: Int64?) -> Track {
        Track(id: id, origin: .server, title: title, artist: "Glass Rivers", albumArtist: "Glass Rivers", album: "Northbound",
              trackNumber: number, discNumber: 1, duration: duration, size: size, suffix: "flac")
    }

    func deviceFile(_ path: String, title: String, number: Int?, duration: TimeInterval, size: Int64, source: String? = nil) -> DeviceFile {
        var info = AudioFileInfo()
        info.title = title
        info.artist = "Glass Rivers"
        info.albumArtist = "Glass Rivers"
        info.album = "Northbound"
        info.trackNumber = number
        info.duration = duration
        return DeviceFile(relativePath: path, size: size, modified: Date(), info: info, sourceTrackID: source)
    }

    @Test func recognisesCopiesAndReencodes() {
        let library = [
            libraryTrack("s1", "Tide", number: 1, duration: 201, size: 31_234_567),
            libraryTrack("s2", "Harbour Lights (Remastered 2020)", number: nil, duration: 250, size: 40_000_000),
            libraryTrack("s3", "Undertow", number: 3, duration: 180, size: 20_000_000),
            libraryTrack("s4", "Lanterns", number: 4, duration: 300, size: 50_000_000),
            libraryTrack("s5", "Glasswork", number: 5, duration: 222, size: 33_000_000),
        ]
        let device = [
            deviceFile("Music/Glass Rivers/Northbound/01 Tide.flac", title: "Tide", number: 1, duration: 201, size: 31_234_567),
            deviceFile("Music/Other/Harbour Lights.mp3", title: "Harbour Lights", number: nil, duration: 251, size: 6_000_000),
            deviceFile("Music/Glass Rivers/Northbound/04 Lanterns.mp3", title: "LANTERNS", number: 4, duration: 299, size: 7_000_000),
            deviceFile("Music/x/renamed.flac", title: "Something else", number: 9, duration: 10, size: 1, source: "s5"),
            deviceFile("Music/Glass Rivers/Northbound/03 Undertow (Live).flac", title: "Undertow (Live)", number: 3, duration: 420, size: 60_000_000),
        ]
        let result = DeviceMatcher.match(library: library, device: device)
        #expect(result.presence["s1"] == .exact("Music/Glass Rivers/Northbound/01 Tide.flac"))
        #expect(result.presence["s2"] == .likely("Music/Other/Harbour Lights.mp3"))
        #expect(result.presence["s3"] == nil, "a live version seven minutes long is a different recording")
        #expect(result.presence["s4"] == .likely("Music/Glass Rivers/Northbound/04 Lanterns.mp3"))
        #expect(result.presence["s5"] == .exact("Music/x/renamed.flac"))
        #expect(result.trackForFile["Music/Glass Rivers/Northbound/01 Tide.flac"] == "s1")
    }

    @Test func matchKeysFoldCaseAccentsAndPunctuation() {
        #expect("Björk — Jóga (Remix)".matchKey == "bjork joga remix")
        #expect("Simon & Garfunkel".matchKey == "simon and garfunkel")
        #expect(DeviceMatcher.looseTitle("Tide (Remastered) [feat. Someone]") == "tide")
        #expect(DeviceMatcher.looseTitle("Tide feat. Someone") == "tide")
    }
}

struct ScannerTests {
    @Test func findsAppleDoubleAndFinderFilesThatFoundationHides() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "discodrome-scan-\(UUID().uuidString)")
        let album = root.appending(path: "Music/Glass Rivers/Northbound")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data("not really audio".utf8).write(to: album.appending(path: "01 Tide.flac"))
        try Data([0, 5, 22, 7]).write(to: album.appending(path: "._01 Tide.flac"))
        try Data("[00:01.00]la".utf8).write(to: album.appending(path: "01 Tide.lrc"))
        try Data([0]).write(to: root.appending(path: ".DS_Store"))
        try FileManager.default.createDirectory(at: root.appending(path: ".Spotlight-V100"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appending(path: ".Spotlight-V100/store.flac"))

        let result = DeviceScanner.scan(root: root, known: [:], capacity: 1 << 30, available: 1 << 29)
        #expect(result.files.map(\.relativePath) == ["Music/Glass Rivers/Northbound/01 Tide.flac"])
        #expect(Set(result.clutter) == ["Music/Glass Rivers/Northbound/._01 Tide.flac", ".DS_Store"])
        #expect(result.files.first?.info.title == "Tide")
        #expect(result.files.first?.info.artist == "Glass Rivers")
        #expect(result.usage.lyricsAndArt == 12)

        #expect(DeviceScanner.removeClutter(result.clutter, root: root) == 2)
        #expect(DeviceScanner.scan(root: root, known: [:], capacity: 1 << 30, available: 1 << 29).clutter.isEmpty)
    }

    @Test func unchangedFilesKeepTheirRecordedOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "discodrome-scan-\(UUID().uuidString)")
        let folder = root.appending(path: "Music/A/B")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "01 Song.mp3")
        try Data(repeating: 0, count: 100).write(to: url)
        let first = DeviceScanner.scan(root: root, known: [:], capacity: 1 << 30, available: 1 << 29).files[0]
        var recorded = first
        recorded.sourceTrackID = "server-song"
        let again = DeviceScanner.scan(root: root, known: [first.relativePath: recorded], capacity: 1 << 30, available: 1 << 29)
        #expect(again.files.first?.sourceTrackID == "server-song")

        try Data(repeating: 1, count: 200).write(to: url)
        let changed = DeviceScanner.scan(root: root, known: [first.relativePath: recorded], capacity: 1 << 30, available: 1 << 29)
        #expect(changed.files.first?.sourceTrackID == nil, "a replaced file isn't the copy we made")
    }
}

struct AppleDoubleTests {
    @Test func removesTwinsOfTheFileAndTheFoldersAboveIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "discodrome-ad-\(UUID().uuidString)")
        let album = root.appending(path: "Music/Artist/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let song = album.appending(path: "01 Song.flac")
        try Data([1]).write(to: song)
        for twin in ["Music/Artist/Album/._01 Song.flac", "Music/Artist/._Album", "Music/._Artist", "._Music"] {
            try Data([0, 5, 22, 7]).write(to: root.appending(path: twin))
        }
        #expect(AppleDouble.removeTwins(of: song, upTo: root) == 4)
        #expect(FileManager.default.fileExists(atPath: song.path))
        #expect(DeviceScanner.scan(root: root, known: [:], capacity: 1 << 30, available: 1 << 29).clutter.isEmpty)
    }
}
