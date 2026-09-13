import Foundation

/// Reads LRC ("[01:23.45]words") and plain lyrics text into `Lyrics`.
public enum LRCParser {
    public static func parse(_ text: String) -> Lyrics {
        var timed: [Lyrics.Line] = []
        var plain: [Lyrics.Line] = []
        var offset: TimeInterval = 0

        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let seconds = timestamp(tag) {
                    stamps.append(seconds)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                } else if stamps.isEmpty, tag.contains(":") {
                    rest = ""   // metadata tag such as [ar:Artist]
                    break
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            if stamps.isEmpty {
                if !rawLine.hasPrefix("[") { plain.append(.init(start: nil, text: words)) }
            } else {
                timed += stamps.map { Lyrics.Line(start: $0, text: words) }
            }
        }

        if timed.count >= 2 || (timed.count == 1 && plain.allSatisfy { $0.text.isEmpty }) {
            let lines = timed
                .map { Lyrics.Line(start: max(0, ($0.start ?? 0) - offset), text: $0.text) }
                .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
            return Lyrics(synced: true, lines: lines)
        }
        // Trim blank lines at both ends but keep stanza breaks.
        while plain.first?.text.isEmpty == true { plain.removeFirst() }
        while plain.last?.text.isEmpty == true { plain.removeLast() }
        return Lyrics(synced: false, lines: plain)
    }

    /// "01:23.45", "1:23", "01:23:450" → seconds.
    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        if parts.count == 2 {
            guard let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
            return TimeInterval(minutes) * 60 + seconds
        }
        guard let seconds = Int(parts[1]), let fraction = Int(parts[2]) else { return nil }
        let divisor = pow(10, Double(parts[2].count))
        return TimeInterval(minutes) * 60 + TimeInterval(seconds) + TimeInterval(fraction) / divisor
    }
}
