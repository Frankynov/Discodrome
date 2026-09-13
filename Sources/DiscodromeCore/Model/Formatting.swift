import Foundation

public enum Formatting {
    /// "3:07", "1:02:09".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "2 hours 14 minutes", "38 minutes" — for album and playlist headers.
    public static func longDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: max(seconds, 60)) ?? duration(seconds)
    }

    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension String {
    /// Folded for matching: case, diacritics and width are ignored, punctuation dropped,
    /// runs of whitespace collapsed. "Björk — Jóga (Remix)" and "bjork joga remix" compare equal.
    public var matchKey: String {
        let folded = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Sort key that ignores a leading article, the way Music does: "The Cure" sorts under C.
    public var librarySortKey: String {
        let lowered = lowercased()
        for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) {
            return String(lowered.dropFirst(article.count))
        }
        return lowered
    }
}
