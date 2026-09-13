import Foundation

/// What the scanner learns from a file's header, without decoding any audio.
public struct AudioFileInfo: Codable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var duration: TimeInterval?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    /// Kilobits per second.
    public var bitRate: Int?
    /// Set where the extension is ambiguous: "alac" or "aac" for .m4a.
    public var codec: String?
    public var musicBrainzTrackID: String?
    public var hasEmbeddedArt = false

    public init() {}
}

/// Header-only tag reader. A card behind a player's USB 2 bridge is slow at random reads, so
/// every parser seeks past artwork and audio instead of reading through them.
public enum AudioTagReader {
    public static let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "mp4", "aac", "alac", "wav", "aif", "aiff", "aifc",
        "ape", "wv", "ogg", "oga", "opus", "dsf", "dff", "wma", "caf",
    ]

    public static func read(_ url: URL) -> AudioFileInfo? {
        guard let file = try? ByteFile(url: url) else { return nil }
        var info = AudioFileInfo()
        let head = file.bytes(0, 12)
        guard head.count >= 4 else { return nil }
        let magic = head.ascii(0, 4)

        switch magic {
        case "fLaC":
            readFLAC(file, at: 0, into: &info)
        case "OggS":
            readOgg(file, into: &info)
        case "RIFF" where head.ascii(8, 4) == "WAVE":
            readWAV(file, into: &info)
        case "FORM" where ["AIFF", "AIFC"].contains(head.ascii(8, 4)):
            readAIFF(file, into: &info)
        case "DSD ":
            readDSF(file, into: &info)
        case "FRM8":
            readDFF(file, into: &info)
        case "MAC ":
            readAPE(file, into: &info)
            readAPEv2(file, into: &info)
        case "wvpk":
            readWavPack(file, into: &info)
            readAPEv2(file, into: &info)
        default:
            if head.count >= 8, head.ascii(4, 4) == "ftyp" {
                readMP4(file, into: &info)
            } else if magic.hasPrefix("ID3") {
                let tagSize = readID3v2(file, at: 0, into: &info)
                if file.bytes(tagSize, 4).ascii(0, 4) == "fLaC" {
                    readFLAC(file, at: tagSize, into: &info)
                } else {
                    readMPEGAudio(file, from: tagSize, into: &info)
                    readAPEv2(file, into: &info)
                    readID3v1(file, into: &info)
                }
            } else if head[0] == 0xFF, head[1] & 0xE0 == 0xE0 {
                readMPEGAudio(file, from: 0, into: &info)
                readAPEv2(file, into: &info)
                readID3v1(file, into: &info)
            } else {
                return url.pathExtension.isEmpty ? nil : info
            }
        }
        return info
    }

    // MARK: - Shared field handling

    static func leadingInt(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Vorbis comments and APEv2 share key names (case-insensitively).
    static func apply(key rawKey: String, value rawValue: String, to info: inout AudioFileInfo) {
        guard let value = clean(rawValue) else { return }
        switch rawKey.uppercased() {
        case "TITLE": if info.title == nil { info.title = value }
        case "ARTIST": if info.artist == nil { info.artist = value }
        case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": if info.albumArtist == nil { info.albumArtist = value }
        case "ALBUM": if info.album == nil { info.album = value }
        case "TRACKNUMBER", "TRACK": if info.trackNumber == nil { info.trackNumber = leadingInt(value) }
        case "DISCNUMBER", "DISC": if info.discNumber == nil { info.discNumber = leadingInt(value) }
        case "DATE", "YEAR": if info.year == nil { info.year = leadingInt(value) }
        case "GENRE": if info.genre == nil { info.genre = value }
        case "MUSICBRAINZ_TRACKID", "MUSICBRAINZ TRACK ID": if info.musicBrainzTrackID == nil { info.musicBrainzTrackID = value }
        case "METADATA_BLOCK_PICTURE", "COVERART", "COVER ART (FRONT)": info.hasEmbeddedArt = true
        default: break
        }
    }

    static func parseVorbisComments(_ b: [UInt8], from start: Int, into info: inout AudioFileInfo) {
        var i = start
        guard i + 4 <= b.count else { return }
        i += 4 + Int(b.le32(i))
        guard i + 4 <= b.count else { return }
        let count = Int(b.le32(i))
        i += 4
        for _ in 0..<min(count, 4096) {
            guard i + 4 <= b.count else { return }
            let length = Int(b.le32(i))
            i += 4
            guard length >= 0, i + length <= b.count else { return }
            let entry = b[i..<i + length]
            if let eq = entry.firstIndex(of: 0x3D) { // "="
                let key = String(decoding: entry[entry.startIndex..<eq], as: UTF8.self)
                if key.uppercased() == "METADATA_BLOCK_PICTURE" {
                    info.hasEmbeddedArt = true
                } else {
                    apply(key: key, value: String(decoding: entry[(eq + 1)...], as: UTF8.self), to: &info)
                }
            }
            i += length
        }
    }

    // MARK: - FLAC

    static func readFLAC(_ f: ByteFile, at start: UInt64, into info: inout AudioFileInfo) {
        var offset = start + 4
        var totalSamples: UInt64 = 0
        for _ in 0..<128 {
            let header = f.bytes(offset, 4)
            guard header.count == 4 else { break }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = UInt64(header.be24(1))
            let body = offset + 4
            switch type {
            case 0:
                let b = f.bytes(body, 34)
                guard b.count == 34 else { break }
                let rate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
                info.sampleRate = rate
                info.channels = Int((b[12] >> 1) & 0x07) + 1
                info.bitDepth = Int((b[12] & 0x01) << 4 | b[13] >> 4) + 1
                totalSamples = UInt64(b[13] & 0x0F) << 32 | UInt64(b.be32(14))
            case 4:
                parseVorbisComments(f.bytes(body, Int(min(length, 1 << 20))), from: 0, into: &info)
            case 6:
                info.hasEmbeddedArt = true
            default:
                break
            }
            offset = body + length
            if isLast { break }
        }
        if let rate = info.sampleRate, rate > 0, totalSamples > 0 {
            let seconds = Double(totalSamples) / Double(rate)
            info.duration = seconds
            if f.size > offset { info.bitRate = Int(Double(f.size - offset) * 8 / seconds / 1000) }
        }
    }

    // MARK: - ID3v2

    private static func syncsafe(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return 0 }
        return Int(b[i] & 0x7F) << 21 | Int(b[i + 1] & 0x7F) << 14 | Int(b[i + 2] & 0x7F) << 7 | Int(b[i + 3] & 0x7F)
    }

    private static func removeUnsynchronisation(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0x00 { i += 2 } else { i += 1 }
        }
        return out
    }

    /// Parses an ID3v2 tag at `offset` and returns its full size (0 when there is none), so
    /// callers know where the audio starts.
    @discardableResult
    static func readID3v2(_ f: ByteFile, at offset: UInt64, into info: inout AudioFileInfo) -> UInt64 {
        let h = f.bytes(offset, 10)
        guard h.count == 10, h.ascii(0, 3) == "ID3" else { return 0 }
        let major = h[3]
        let flags = h[5]
        let bodySize = UInt64(syncsafe(h, 6))
        let total = 10 + bodySize + ((major == 4 && flags & 0x10 != 0) ? 10 : 0)
        guard (2...4).contains(major) else { return total }

        let read: (UInt64, Int) -> [UInt8]
        if flags & 0x80 != 0 && major < 4 {
            let whole = removeUnsynchronisation(f.bytes(offset + 10, Int(min(bodySize, 16 << 20))))
            read = { position, count in
                guard position < UInt64(whole.count) else { return [] }
                let start = Int(position)
                return Array(whole[start..<min(whole.count, start + count)])
            }
        } else {
            read = { position, count in f.bytes(offset + 10 + position, count) }
        }

        var position: UInt64 = 0
        if flags & 0x40 != 0, major >= 3 {
            let e = read(0, 4)
            position = major == 4 ? UInt64(syncsafe(e, 0)) : UInt64(e.be32(0)) + 4
        }
        let headerLength: UInt64 = major == 2 ? 6 : 10
        while position + headerLength <= bodySize {
            let fh = read(position, Int(headerLength))
            guard fh.count == Int(headerLength), fh[0] != 0 else { break }
            let id: String
            let size: UInt64
            var frameFlags = 0
            if major == 2 {
                id = fh.ascii(0, 3)
                size = UInt64(fh.be24(3))
            } else {
                id = fh.ascii(0, 4)
                size = major == 4 ? UInt64(syncsafe(fh, 4)) : UInt64(fh.be32(4))
                frameFlags = fh.be16(8)
            }
            guard size > 0, id.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { break }
            let dataOffset = position + headerLength

            if id == "APIC" || id == "PIC" {
                info.hasEmbeddedArt = true
            } else if size <= 64_000, id.hasPrefix("T") || id.hasPrefix("UFI") {
                var data = read(dataOffset, Int(size))
                var readable = true
                if major == 4 {
                    if frameFlags & 0x000C != 0 { readable = false }             // compressed / encrypted
                    if frameFlags & 0x0040 != 0 { data = Array(data.dropFirst()) } // grouping id
                    if frameFlags & 0x0002 != 0 { data = removeUnsynchronisation(data) }
                    if frameFlags & 0x0001 != 0 { data = Array(data.dropFirst(4)) } // data length indicator
                } else if major == 3 {
                    if frameFlags & 0x00C0 != 0 { readable = false }
                    if frameFlags & 0x0020 != 0 { data = Array(data.dropFirst()) }
                }
                if readable { applyID3Frame(id, data, into: &info) }
            }
            position = dataOffset + size
        }
        return total
    }

    private static func decodeID3Strings(_ data: ArraySlice<UInt8>, encoding: UInt8) -> [String] {
        var parts: [ArraySlice<UInt8>] = []
        if encoding == 1 || encoding == 2 {
            var start = data.startIndex
            var i = data.startIndex
            while i + 1 < data.endIndex {
                if data[i] == 0, data[i + 1] == 0 {
                    parts.append(data[start..<i])
                    start = i + 2
                }
                i += 2
            }
            if start < data.endIndex { parts.append(data[start..<data.endIndex]) }
        } else {
            parts = data.split(separator: 0, omittingEmptySubsequences: false)
        }
        return parts.compactMap { part -> String? in
            let bytes = Array(part)
            let string: String?
            switch encoding {
            case 0: string = String(bytes: bytes, encoding: .isoLatin1)
            case 1: string = String(bytes: bytes, encoding: .utf16)
            case 2: string = String(bytes: bytes, encoding: .utf16BigEndian)
            default: string = String(bytes: bytes, encoding: .utf8)
            }
            return string.flatMap(clean)
        }
    }

    private static func applyID3Frame(_ id: String, _ data: [UInt8], into info: inout AudioFileInfo) {
        guard let encoding = data.first else { return }
        if id == "UFID" || id == "UFI" {
            guard let zero = data.firstIndex(of: 0) else { return }
            let owner = String(decoding: data[..<zero], as: UTF8.self)
            if owner == "http://musicbrainz.org", info.musicBrainzTrackID == nil {
                info.musicBrainzTrackID = clean(String(decoding: data[(zero + 1)...], as: UTF8.self))
            }
            return
        }
        let strings = decodeID3Strings(data.dropFirst(), encoding: encoding)
        if id == "TXXX" || id == "TXX" {
            guard strings.count >= 2 else { return }
            switch strings[0].uppercased() {
            case "ALBUMARTIST", "ALBUM ARTIST": if info.albumArtist == nil { info.albumArtist = strings[1] }
            case "MUSICBRAINZ TRACK ID": if info.musicBrainzTrackID == nil { info.musicBrainzTrackID = strings[1] }
            default: break
            }
            return
        }
        guard let value = strings.first else { return }
        switch id {
        case "TIT2", "TT2": info.title = info.title ?? value
        case "TPE1", "TP1": info.artist = info.artist ?? value
        case "TPE2", "TP2": info.albumArtist = info.albumArtist ?? value
        case "TALB", "TAL": info.album = info.album ?? value
        case "TRCK", "TRK": info.trackNumber = info.trackNumber ?? leadingInt(value)
        case "TPOS", "TPA": info.discNumber = info.discNumber ?? leadingInt(value)
        case "TYER", "TYE", "TDRC", "TDOR": info.year = info.year ?? leadingInt(value)
        case "TCON", "TCO": info.genre = info.genre ?? id3Genre(value)
        default: break
        }
    }

    private static let id3v1Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop",
        "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game",
        "Sound Clip", "Gospel", "Noise", "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial",
        "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave",
        "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka",
        "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]

    /// "(17)", "(17)Rock", "17" and "Rock" all mean Rock.
    static func id3Genre(_ value: String) -> String? {
        var text = value
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            let number = Int(text[text.index(after: text.startIndex)..<close])
            let rest = String(text[text.index(after: close)...])
            if let rest = clean(rest) { return rest }
            text = number.map(String.init) ?? ""
        }
        if let number = Int(text) { return number < id3v1Genres.count ? id3v1Genres[number] : nil }
        return clean(text)
    }

    static func readID3v1(_ f: ByteFile, into info: inout AudioFileInfo) {
        guard f.size >= 128 else { return }
        let b = f.bytes(f.size - 128, 128)
        guard b.count == 128, b.ascii(0, 3) == "TAG" else { return }
        func field(_ start: Int, _ length: Int) -> String? {
            clean(String(bytes: b[start..<start + length], encoding: .isoLatin1) ?? "")
        }
        info.title = info.title ?? field(3, 30)
        info.artist = info.artist ?? field(33, 30)
        info.album = info.album ?? field(63, 30)
        info.year = info.year ?? field(93, 4).flatMap(leadingInt)
        if b[125] == 0, b[126] != 0 { info.trackNumber = info.trackNumber ?? Int(b[126]) }
        if info.genre == nil, Int(b[127]) < id3v1Genres.count { info.genre = id3v1Genres[Int(b[127])] }
    }

    // MARK: - MPEG audio

    private struct MPEGFrame {
        let sampleRate: Int
        let bitRate: Int
        let channels: Int
        let samplesPerFrame: Int
        let length: Int
        let isVersion1: Bool

        private static let v1Rates = [44100, 48000, 32000]
        private static let bitrates: [[Int]] = [
            [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // V1 L1
            [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],    // V1 L2
            [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],     // V1 L3
            [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],    // V2 L1
            [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],         // V2 L2/L3
        ]

        init?(_ b: [UInt8], _ i: Int) {
            guard i + 4 <= b.count, b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { return nil }
            let versionBits = (b[i + 1] >> 3) & 0x03
            let layerBits = (b[i + 1] >> 1) & 0x03
            let bitrateIndex = Int(b[i + 2] >> 4)
            let rateIndex = Int((b[i + 2] >> 2) & 0x03)
            guard versionBits != 1, layerBits != 0, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }
            let layer = 4 - Int(layerBits)
            isVersion1 = versionBits == 3
            let divisor = versionBits == 3 ? 1 : (versionBits == 2 ? 2 : 4)
            sampleRate = Self.v1Rates[rateIndex] / divisor
            let table = isVersion1 ? layer - 1 : (layer == 1 ? 3 : 4)
            bitRate = Self.bitrates[table][bitrateIndex - 1]
            channels = (b[i + 3] >> 6) == 3 ? 1 : 2
            samplesPerFrame = layer == 1 ? 384 : (layer == 2 || isVersion1 ? 1152 : 576)
            let padding = Int((b[i + 2] >> 1) & 0x01)
            length = layer == 1
                ? (12 * bitRate * 1000 / sampleRate + padding) * 4
                : samplesPerFrame / 8 * bitRate * 1000 / sampleRate + padding
            guard length > 4 else { return nil }
        }
    }

    static func readMPEGAudio(_ f: ByteFile, from start: UInt64, into info: inout AudioFileInfo) {
        let b = f.bytes(start, 32_768)
        var i = 0
        var frame: MPEGFrame?
        while i + 4 <= b.count {
            if let candidate = MPEGFrame(b, i) {
                // Confirm with the following frame header when it's in the window.
                let next = i + candidate.length
                if next + 4 > b.count || MPEGFrame(b, next) != nil {
                    frame = candidate
                    break
                }
            }
            i += 1
        }
        guard let frame else { return }
        info.sampleRate = frame.sampleRate
        info.channels = frame.channels
        let audioBytes = Double(f.size - start - UInt64(i))

        let sideInfo = frame.isVersion1 ? (frame.channels == 1 ? 17 : 32) : (frame.channels == 1 ? 9 : 17)
        let xing = i + 4 + sideInfo
        var frameCount: Int?
        if ["Xing", "Info"].contains(b.ascii(xing, 4)), b.be32(xing + 4) & 0x01 != 0 {
            frameCount = Int(b.be32(xing + 8))
        } else if b.ascii(i + 36, 4) == "VBRI" {
            frameCount = Int(b.be32(i + 36 + 14))
        }
        if let frameCount, frameCount > 0 {
            let seconds = Double(frameCount * frame.samplesPerFrame) / Double(frame.sampleRate)
            info.duration = seconds
            info.bitRate = Int(audioBytes * 8 / seconds / 1000)
        } else {
            info.bitRate = frame.bitRate
            info.duration = audioBytes * 8 / Double(frame.bitRate * 1000)
        }
    }

    // MARK: - MP4 / M4A

    private struct MP4State {
        var timescale: UInt64 = 0
        var duration: UInt64 = 0
        var mediaBytes: UInt64 = 0
        var inItemList = false
    }

    static func readMP4(_ f: ByteFile, into info: inout AudioFileInfo) {
        var state = MP4State()
        walkMP4(f, from: 0, to: f.size, depth: 0, state: &state, info: &info)
        if state.timescale > 0, state.duration > 0 {
            let seconds = Double(state.duration) / Double(state.timescale)
            info.duration = seconds
            if state.mediaBytes > 0 { info.bitRate = Int(Double(state.mediaBytes) * 8 / seconds / 1000) }
        }
    }

    private static func walkMP4(_ f: ByteFile, from start: UInt64, to end: UInt64, depth: Int, state: inout MP4State, info: inout AudioFileInfo) {
        guard depth < 12 else { return }
        var offset = start
        while offset + 8 <= end {
            let h = f.bytes(offset, 16)
            guard h.count >= 8 else { return }
            var size = UInt64(h.be32(0))
            let type = h.ascii(4, 4)
            var headerLength: UInt64 = 8
            if size == 1 {
                guard h.count == 16 else { return }
                size = h.be64(8)
                headerLength = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerLength, offset + size <= end else { return }
            let body = offset + headerLength
            let bodyEnd = offset + size

            switch type {
            case "moov", "trak", "mdia", "minf", "stbl", "udta":
                walkMP4(f, from: body, to: bodyEnd, depth: depth + 1, state: &state, info: &info)
            case "meta":
                // iTunes writes `meta` as a full box (4 bytes of version/flags); QuickTime doesn't.
                let peek = f.bytes(body, 12)
                let skip: UInt64 = peek.ascii(8, 4) == "hdlr" ? 4 : 0
                walkMP4(f, from: body + skip, to: bodyEnd, depth: depth + 1, state: &state, info: &info)
            case "ilst":
                state.inItemList = true
                walkMP4(f, from: body, to: bodyEnd, depth: depth + 1, state: &state, info: &info)
                state.inItemList = false
            case "mvhd":
                let b = f.bytes(body, 32)
                guard b.count >= 32 else { break }
                if b[0] == 1 {
                    state.timescale = UInt64(b.be32(20)); state.duration = b.be64(24)
                } else {
                    state.timescale = UInt64(b.be32(12)); state.duration = UInt64(b.be32(16))
                }
            case "mdat":
                state.mediaBytes += size - headerLength
            case "stsd" where info.codec == nil:
                let b = f.bytes(body, 96)
                guard b.count >= 44 else { break }
                let entry = b.ascii(12, 4)
                info.codec = entry == "mp4a" ? "aac" : entry.trimmingCharacters(in: .whitespaces).lowercased()
                info.channels = b.be16(32)
                info.bitDepth = entry == "mp4a" ? nil : b.be16(34)
                info.sampleRate = Int(b.be32(40) >> 16)
                if entry == "alac", b.count >= 80, b.ascii(48, 4) == "alac" {
                    info.bitDepth = Int(b[61])
                    info.channels = Int(b[65])
                    info.sampleRate = Int(b.be32(76))
                }
            case "covr" where state.inItemList:
                info.hasEmbeddedArt = true
            default:
                if state.inItemList, size <= 65_536 {
                    applyMP4Item(type, f.bytes(body, Int(size - headerLength)), into: &info)
                }
            }
            offset = bodyEnd
        }
    }

    private static func applyMP4Item(_ type: String, _ b: [UInt8], into info: inout AudioFileInfo) {
        // Children: optional `mean` and `name` (freeform items), then `data`.
        var i = 0
        var name: String?
        while i + 8 <= b.count {
            let size = Int(b.be32(i))
            guard size >= 8, i + size <= b.count else { return }
            let child = b.ascii(i + 4, 4)
            if child == "name", size > 12 {
                name = String(decoding: b[(i + 12)..<(i + size)], as: UTF8.self)
            } else if child == "data", size >= 16 {
                let value = Array(b[(i + 16)..<(i + size)])
                let text = clean(String(decoding: value, as: UTF8.self))
                switch type {
                case "©nam": info.title = info.title ?? text
                case "©ART": info.artist = info.artist ?? text
                case "aART": info.albumArtist = info.albumArtist ?? text
                case "©alb": info.album = info.album ?? text
                case "©day": info.year = info.year ?? text.flatMap(leadingInt)
                case "©gen": info.genre = info.genre ?? text
                case "gnre": if info.genre == nil, value.count >= 2 { info.genre = id3Genre(String(value.be16(0) - 1)) }
                case "trkn": if info.trackNumber == nil, value.count >= 4 { info.trackNumber = value.be16(2) }
                case "disk": if info.discNumber == nil, value.count >= 4 { info.discNumber = value.be16(2) }
                case "----":
                    if name == "MusicBrainz Track Id" { info.musicBrainzTrackID = info.musicBrainzTrackID ?? text }
                default: break
                }
                return
            }
            i += size
        }
    }

    // MARK: - Ogg (Vorbis, Opus)

    static func readOgg(_ f: ByteFile, into info: inout AudioFileInfo) {
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var offset: UInt64 = 0
        var serial: UInt32?
        pages: while packets.count < 2, offset < f.size, offset < 2 << 20 {
            let h = f.bytes(offset, 27)
            guard h.count == 27, h.ascii(0, 4) == "OggS" else { break }
            let pageSerial = h.le32(14)
            let segments = Int(h[26])
            let table = f.bytes(offset + 27, segments)
            guard table.count == segments else { break }
            let bodySize = table.reduce(0) { $0 + Int($1) }
            let body = f.bytes(offset + 27 + UInt64(segments), bodySize)
            offset += 27 + UInt64(segments) + UInt64(bodySize)
            if serial == nil { serial = pageSerial }
            guard pageSerial == serial else { continue }
            var cursor = 0
            for lace in table {
                let end = min(cursor + Int(lace), body.count)
                current += body[cursor..<end]
                cursor = end
                if lace < 255 {
                    packets.append(current)
                    current = []
                    if packets.count == 2 { break pages }
                }
            }
            if current.count > 1 << 20 { packets.append(current); break }
        }

        var granuleRate = 0
        var preSkip = 0
        if let id = packets.first {
            if id.count >= 16, id[0] == 1, id.ascii(1, 6) == "vorbis" {
                info.codec = "vorbis"
                info.channels = Int(id[11])
                info.sampleRate = Int(id.le32(12))
                granuleRate = info.sampleRate ?? 0
                let nominal = Int(Int32(bitPattern: id.le32(20)))
                if nominal > 0 { info.bitRate = nominal / 1000 }
            } else if id.count >= 16, id.ascii(0, 8) == "OpusHead" {
                info.codec = "opus"
                info.channels = Int(id[9])
                preSkip = id.le16(10)
                info.sampleRate = 48_000
                granuleRate = 48_000
            } else if id.count >= 13, id[0] == 0x7F, id.ascii(1, 4) == "FLAC" {
                info.codec = "flac"
            }
        }
        if packets.count >= 2 {
            let comments = packets[1]
            if comments.count > 7, comments[0] == 3, comments.ascii(1, 6) == "vorbis" {
                parseVorbisComments(comments, from: 7, into: &info)
            } else if comments.count > 8, comments.ascii(0, 8) == "OpusTags" {
                parseVorbisComments(comments, from: 8, into: &info)
            }
        }

        // Duration: the granule position of the last page.
        guard granuleRate > 0 else { return }
        let tailLength = Int(min(f.size, 65_536))
        let tail = f.bytes(f.size - UInt64(tailLength), tailLength)
        var i = tail.count - 27
        while i >= 0 {
            if tail[i] == 0x4F, tail.ascii(i, 4) == "OggS" {
                let granule = tail.le64(i + 6)
                if granule > 0, granule != UInt64.max {
                    let seconds = Double(Int64(granule) - Int64(preSkip)) / Double(granuleRate)
                    info.duration = seconds
                    if info.bitRate == nil, seconds > 0 { info.bitRate = Int(Double(f.size) * 8 / seconds / 1000) }
                }
                break
            }
            i -= 1
        }
    }

    // MARK: - WAV, AIFF

    static func readWAV(_ f: ByteFile, into info: inout AudioFileInfo) {
        var offset: UInt64 = 12
        var byteRate = 0
        while offset + 8 <= f.size {
            let h = f.bytes(offset, 8)
            guard h.count == 8 else { break }
            let id = h.ascii(0, 4)
            let size = UInt64(h.le32(4))
            let body = offset + 8
            switch id {
            case "fmt ":
                let b = f.bytes(body, 16)
                guard b.count == 16 else { break }
                info.channels = b.le16(2)
                info.sampleRate = Int(b.le32(4))
                byteRate = Int(b.le32(8))
                info.bitDepth = b.le16(14)
                info.bitRate = byteRate * 8 / 1000
            case "data":
                if byteRate > 0 { info.duration = Double(size) / Double(byteRate) }
            case "LIST":
                let b = f.bytes(body, Int(min(size, 65_536)))
                guard b.ascii(0, 4) == "INFO" else { break }
                var i = 4
                while i + 8 <= b.count {
                    let key = b.ascii(i, 4)
                    let length = Int(b.le32(i + 4))
                    guard i + 8 + length <= b.count else { break }
                    let value = String(bytes: b[(i + 8)..<(i + 8 + length)], encoding: .utf8)
                        ?? String(bytes: b[(i + 8)..<(i + 8 + length)], encoding: .isoLatin1) ?? ""
                    switch key {
                    case "INAM": info.title = info.title ?? clean(value)
                    case "IART": info.artist = info.artist ?? clean(value)
                    case "IPRD": info.album = info.album ?? clean(value)
                    case "ITRK", "IPRT": info.trackNumber = info.trackNumber ?? leadingInt(value)
                    case "ICRD": info.year = info.year ?? leadingInt(value)
                    case "IGNR": info.genre = info.genre ?? clean(value)
                    default: break
                    }
                    i += 8 + length + (length & 1)
                }
            case "id3 ", "ID3 ":
                readID3v2(f, at: body, into: &info)
            default:
                break
            }
            offset = body + size + (size & 1)
        }
    }

    static func readAIFF(_ f: ByteFile, into info: inout AudioFileInfo) {
        var offset: UInt64 = 12
        while offset + 8 <= f.size {
            let h = f.bytes(offset, 8)
            guard h.count == 8 else { break }
            let id = h.ascii(0, 4)
            let size = UInt64(h.be32(4))
            let body = offset + 8
            switch id {
            case "COMM":
                let b = f.bytes(body, 18)
                guard b.count == 18 else { break }
                info.channels = b.be16(0)
                let frames = Double(b.be32(2))
                info.bitDepth = b.be16(6)
                let rate = extended80(b, 8)
                if rate > 0 {
                    info.sampleRate = Int(rate)
                    info.duration = frames / rate
                    info.bitRate = Int(rate) * (info.bitDepth ?? 16) * (info.channels ?? 2) / 1000
                }
            case "ID3 ", "id3 ":
                readID3v2(f, at: body, into: &info)
            case "NAME":
                info.title = info.title ?? clean(String(decoding: f.bytes(body, Int(min(size, 1024))), as: UTF8.self))
            default:
                break
            }
            offset = body + size + (size & 1)
        }
    }

    /// IEEE 754 80-bit extended, as AIFF stores its sample rate.
    static func extended80(_ b: [UInt8], _ i: Int) -> Double {
        guard i + 10 <= b.count else { return 0 }
        let exponent = Int(b.be16(i) & 0x7FFF)
        let mantissa = b.be64(i + 2)
        guard exponent != 0 || mantissa != 0 else { return 0 }
        return Double(mantissa) * pow(2, Double(exponent - 16383 - 63))
    }

    // MARK: - DSD

    static func readDSF(_ f: ByteFile, into info: inout AudioFileInfo) {
        let b = f.bytes(0, 80)
        guard b.count >= 72, b.ascii(28, 4) == "fmt " else { return }
        info.channels = Int(b.le32(52))
        info.sampleRate = Int(b.le32(56))
        info.bitDepth = 1
        let samples = b.le64(64)
        if let rate = info.sampleRate, rate > 0 {
            info.duration = Double(samples) / Double(rate)
            info.bitRate = rate * (info.channels ?? 2) / 1000
        }
        let metadata = b.le64(20)
        if metadata > 0, metadata < f.size { readID3v2(f, at: metadata, into: &info) }
    }

    static func readDFF(_ f: ByteFile, into info: inout AudioFileInfo) {
        info.bitDepth = 1
        var offset: UInt64 = 16
        var end = f.size
        var soundBytes: UInt64 = 0
        while offset + 12 <= end {
            let h = f.bytes(offset, 12)
            guard h.count == 12 else { break }
            let id = h.ascii(0, 4)
            let size = h.be64(4)
            let body = offset + 12
            switch id {
            case "PROP":
                offset = body + 4 // "SND " then local chunks
                end = min(f.size, body + size)
                continue
            case "FS  ": info.sampleRate = Int(f.bytes(body, 4).be32(0))
            case "CHNL": info.channels = f.bytes(body, 2).be16(0)
            case "DSD ": soundBytes = size
            case "ID3 ": readID3v2(f, at: body, into: &info)
            default: break
            }
            offset = body + size + (size & 1)
            if offset >= end && end < f.size { end = f.size } // leave PROP, continue at top level
        }
        if let rate = info.sampleRate, rate > 0, soundBytes > 0 {
            let channels = UInt64(max(info.channels ?? 2, 1))
            info.duration = Double(soundBytes * 8 / channels) / Double(rate)
            info.bitRate = rate * Int(channels) / 1000
        }
    }

    // MARK: - Monkey's Audio, WavPack, APEv2

    static func readAPE(_ f: ByteFile, into info: inout AudioFileInfo) {
        let b = f.bytes(0, 128)
        guard b.count >= 64 else { return }
        let version = b.le16(4)
        var blocksPerFrame = 0, finalFrameBlocks = 0, totalFrames = 0
        if version >= 3980 {
            let header = Int(b.le32(8))
            guard header + 24 <= b.count else { return }
            blocksPerFrame = Int(b.le32(header + 4))
            finalFrameBlocks = Int(b.le32(header + 8))
            totalFrames = Int(b.le32(header + 12))
            info.bitDepth = b.le16(header + 16)
            info.channels = b.le16(header + 18)
            info.sampleRate = Int(b.le32(header + 20))
        } else {
            let compression = b.le16(6)
            let formatFlags = b.le16(8)
            info.channels = b.le16(10)
            info.sampleRate = Int(b.le32(12))
            totalFrames = Int(b.le32(24))
            finalFrameBlocks = Int(b.le32(28))
            blocksPerFrame = version >= 3950 ? 73_440 * 4 : (version >= 3900 || (version >= 3800 && compression == 4000)) ? 73_440 : 9_216
            info.bitDepth = formatFlags & 0x01 != 0 ? 8 : (formatFlags & 0x08 != 0 ? 24 : 16)
        }
        if let rate = info.sampleRate, rate > 0, totalFrames > 0 {
            let blocks = (totalFrames - 1) * blocksPerFrame + finalFrameBlocks
            info.duration = Double(blocks) / Double(rate)
            info.bitRate = Int(Double(f.size) * 8 / info.duration! / 1000)
        }
    }

    static func readWavPack(_ f: ByteFile, into info: inout AudioFileInfo) {
        let b = f.bytes(0, 32)
        guard b.count == 32 else { return }
        let total = b.le32(12)
        let flags = b.le32(24)
        let rates = [6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000, 192000]
        let rateIndex = Int((flags >> 23) & 0x0F)
        info.bitDepth = Int(flags & 0x03 + 1) * 8
        info.channels = flags & 0x04 != 0 ? 1 : 2
        if rateIndex < rates.count { info.sampleRate = rates[rateIndex] }
        if total != 0xFFFF_FFFF, let rate = info.sampleRate {
            info.duration = Double(total) / Double(rate)
            if total > 0 { info.bitRate = Int(Double(f.size) * 8 / info.duration! / 1000) }
        }
    }

    static func readAPEv2(_ f: ByteFile, into info: inout AudioFileInfo) {
        for trailing: UInt64 in [0, 128] where f.size >= 32 + trailing {
            let footerOffset = f.size - trailing - 32
            let footer = f.bytes(footerOffset, 32)
            guard footer.ascii(0, 8) == "APETAGEX" else { continue }
            let tagSize = UInt64(footer.le32(12))
            let count = Int(footer.le32(16))
            guard tagSize >= 32, tagSize <= footerOffset + 32, tagSize < 16 << 20 else { return }
            let itemsStart = footerOffset + 32 - tagSize
            let b = f.bytes(itemsStart, Int(tagSize - 32))
            var i = 0
            for _ in 0..<min(count, 512) {
                guard i + 8 <= b.count else { return }
                let valueSize = Int(b.le32(i))
                let itemFlags = b.le32(i + 4)
                guard let zero = b[(i + 8)...].firstIndex(of: 0) else { return }
                let key = String(decoding: b[(i + 8)..<zero], as: UTF8.self)
                let valueStart = zero + 1
                guard valueSize >= 0, valueStart + valueSize <= b.count else { return }
                if (itemFlags >> 1) & 0x03 == 1 {
                    if key.lowercased().hasPrefix("cover art") { info.hasEmbeddedArt = true }
                } else {
                    apply(key: key, value: String(decoding: b[valueStart..<(valueStart + valueSize)], as: UTF8.self), to: &info)
                }
                i = valueStart + valueSize
            }
            return
        }
    }
}

// MARK: - Byte access

/// Reads a file through a 64 KB window, so header parsing makes few actual reads.
public final class ByteFile {
    private let handle: FileHandle
    public let size: UInt64
    private var windowStart: UInt64 = 0
    private var window: [UInt8] = []
    private static let windowSize = 64 * 1024

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    /// Up to `count` bytes starting at `offset`; fewer at the end of the file.
    public func bytes(_ offset: UInt64, _ count: Int) -> [UInt8] {
        guard count > 0, offset < size else { return [] }
        let available = Int(min(UInt64(count), size - offset))
        if offset >= windowStart, offset + UInt64(available) <= windowStart + UInt64(window.count) {
            let start = Int(offset - windowStart)
            return Array(window[start..<(start + available)])
        }
        if available > Self.windowSize { return rawRead(offset, available) }
        windowStart = offset
        window = rawRead(offset, Int(min(UInt64(Self.windowSize), size - offset)))
        return Array(window.prefix(available))
    }

    private func rawRead(_ offset: UInt64, _ count: Int) -> [UInt8] {
        do {
            try handle.seek(toOffset: offset)
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        } catch {
            return []
        }
    }
}

extension Array where Element == UInt8 {
    func be16(_ i: Int) -> Int { i >= 0 && i + 2 <= count ? Int(self[i]) << 8 | Int(self[i + 1]) : 0 }
    func be24(_ i: Int) -> Int { i >= 0 && i + 3 <= count ? Int(self[i]) << 16 | Int(self[i + 1]) << 8 | Int(self[i + 2]) : 0 }
    func be32(_ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= count else { return 0 }
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    func be64(_ i: Int) -> UInt64 { UInt64(be32(i)) << 32 | UInt64(be32(i + 4)) }
    func le16(_ i: Int) -> Int { i >= 0 && i + 2 <= count ? Int(self[i]) | Int(self[i + 1]) << 8 : 0 }
    func le32(_ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= count else { return 0 }
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    func le64(_ i: Int) -> UInt64 { UInt64(le32(i)) | UInt64(le32(i + 4)) << 32 }
    func ascii(_ i: Int, _ length: Int) -> String {
        guard i >= 0, i + length <= count else { return "" }
        return String(bytes: self[i..<(i + length)], encoding: .isoLatin1) ?? ""
    }
}
