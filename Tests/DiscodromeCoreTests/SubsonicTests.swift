import Foundation
import Testing
@testable import DiscodromeCore

struct SubsonicTests {
    @Test func tokenMatchesTheSubsonicSpecExample() {
        // subsonic.org/pages/api.jsp: password "sesame", salt "c19b2d".
        #expect(ServerCredentials.token(password: "sesame", salt: "c19b2d") == "26719a1196d2a940705a59634eb18eab")
    }

    @Test func queryValuesAreStrictlyEscaped() {
        let credentials = ServerCredentials(serverURL: URL(string: "http://host:4533/navidrome")!, username: "a+b c", token: "t", salt: "s")
        let url = SubsonicClient(credentials: credentials).endpointURL("search3", [("query", "AC/DC & co")])
        #expect(url.absoluteString.hasPrefix("http://host:4533/navidrome/rest/search3.view?"))
        #expect(url.absoluteString.contains("u=a%2Bb%20c"))
        #expect(url.absoluteString.contains("query=AC%2FDC%20%26%20co"))
        #expect(url.absoluteString.contains("c=Discodrome"))
    }

    @Test func typedAddressesAreNormalised() {
        #expect(ServerCredentials.normalizedServerURL("music.home:4533/")?.absoluteString == "http://music.home:4533")
        #expect(ServerCredentials.normalizedServerURL(" https://example.org/nd/ ")?.absoluteString == "https://example.org/nd")
        #expect(ServerCredentials.normalizedServerURL("   ") == nil)
        #expect(ServerCredentials.normalizedServerURL("ftp://example.org") == nil)
    }

    @Test func decodesNavidromeAlbumWithHiResSong() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.58.0 (abc)","openSubsonic":true,
         "album":{"id":"al1","name":"Northbound","artist":"Glass Rivers","artistId":"ar1","coverArt":"al-al1","songCount":1,"duration":201,
          "year":2021,"created":"2024-03-01T10:21:33.123456789Z",
          "song":[{"id":"s1","parent":"al1","isDir":false,"title":"Tide","album":"Northbound","artist":"Glass Rivers","track":1,
           "discNumber":1,"year":2021,"coverArt":"mf-s1","size":31234567,"contentType":"audio/flac","suffix":"flac","duration":201,
           "bitRate":1411,"bitDepth":24,"samplingRate":96000,"channelCount":2,"path":"Glass Rivers/Northbound/01 - Tide.flac",
           "albumId":"al1","artistId":"ar1","type":"music","created":"2024-03-01T10:21:33Z","displayAlbumArtist":"Glass Rivers"}]}}}
        """
        let root = try SubsonicDate.decoder().decode(SubsonicRoot<AlbumPayload>.self, from: Data(json.utf8))
        let dto = try #require(root.body.payload?.album)
        let track = try #require(dto.song?.first?.track_)
        #expect(root.body.serverType == "navidrome")
        #expect(dto.album.name == "Northbound")
        #expect(dto.album.created != nil)
        #expect(track.formatLabel == "FLAC 24/96")
        #expect(track.isHiRes)
        #expect(track.albumArtist == "Glass Rivers")
        #expect(track.path == "Glass Rivers/Northbound/01 - Tide.flac")
    }

    @Test func decodesFailures() throws {
        let json = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#
        let root = try SubsonicDate.decoder().decode(SubsonicRoot<AlbumPayload>.self, from: Data(json.utf8))
        #expect(root.body.error?.code == 40)
        #expect(root.body.payload == nil)
        #expect(SubsonicError.api(code: 40, message: "x").errorDescription == "Wrong username or password.")
    }

    @Test func decodesStructuredLyricsWithOffset() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[
          {"lang":"eng","synced":true,"offset":-250,"line":[{"start":1000,"value":"First"},{"start":4500,"value":"Second"}]}]}}}
        """
        let root = try SubsonicDate.decoder().decode(SubsonicRoot<LyricsListPayload>.self, from: Data(json.utf8))
        let lyrics = try #require(root.body.payload?.lyricsList.structuredLyrics?.first?.lyrics)
        #expect(lyrics.synced)
        #expect(lyrics.lines.map(\.start) == [0.75, 4.25])
    }
}

struct LyricsTests {
    @Test func parsesSyncedLRC() {
        let lyrics = LRCParser.parse("[ar:Someone]\n[00:01.50]Hello\n[00:03.25][00:10.00]Again\n[offset:+500]\n")
        #expect(lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["Hello", "Again", "Again"])
        #expect(lyrics.lines.map(\.start) == [1.0, 2.75, 9.5])
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lineIndex(at: 3.0) == 1)
        #expect(lyrics.lineIndex(at: 60) == 2)
    }

    @Test func plainTextStaysUnsynced() {
        let lyrics = LRCParser.parse("\nFirst verse\n\nSecond verse\n")
        #expect(!lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["First verse", "", "Second verse"])
    }

    @Test func writesLRCForTheDevice() throws {
        let lyrics = Lyrics(synced: true, lines: [.init(start: 61.25, text: "Line")])
        let text = try #require(lyrics.lrcText(title: "T", artist: "A", album: "B"))
        #expect(text.contains("[ti:T]"))
        #expect(text.contains("[01:01.25]Line"))
        #expect(LRCParser.parse(text).lines.first?.start == 61.25)
    }
}

struct PathTests {
    func track(title: String, artist: String = "AC/DC", album: String = "Live...", number: Int? = 3, disc: Int? = 2) -> Track {
        Track(id: "1", origin: .server, title: title, artist: artist, albumArtist: artist, album: album,
              trackNumber: number, discNumber: disc, suffix: "flac")
    }

    @Test func buildsFATSafePaths() {
        let path = DevicePathBuilder().relativePath(for: track(title: "What's Up? / Live: Remix"), suffix: "flac", discCount: 2)
        #expect(path == "Music/AC-DC/Live/2-03 What's Up_ - Live - Remix.flac")
    }

    @Test func singleDiscAlbumsHaveNoDiscPrefix() {
        let path = DevicePathBuilder().relativePath(for: track(title: "Tide", disc: 1), suffix: "flac", discCount: 1)
        #expect(path == "Music/AC-DC/Live/03 Tide.flac")
    }

    @Test func missingTrackNumbersDontLeaveDebris() {
        let path = DevicePathBuilder(musicFolder: "").relativePath(for: track(title: "Tide", number: nil, disc: nil), suffix: "mp3")
        #expect(path == "AC-DC/Live/Tide.mp3")
    }

    @Test func reservedAndHiddenNamesAreDefused() {
        #expect(DevicePathBuilder.sanitizeComponent("CON") == "CON_")
        #expect(DevicePathBuilder.sanitizeComponent(".hidden") == "_hidden")
        #expect(DevicePathBuilder.sanitizeComponent("  trailing. . ") == "trailing")
        #expect(DevicePathBuilder.sanitizeComponent("e\u{301}te\u{301}") == "\u{e9}t\u{e9}")
    }
}
