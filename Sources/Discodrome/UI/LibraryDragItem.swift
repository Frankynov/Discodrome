import AppKit
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Declared in the app's Info.plist (see build.sh).
    static let discodromeItem = UTType(exportedAs: "com.discodrome.library-item")
}

extension NSPasteboard.PasteboardType {
    static let discodromeItem = NSPasteboard.PasteboardType(UTType.discodromeItem.identifier)
}

/// What travels on the pasteboard when songs, albums or playlists are dragged. The AppKit song
/// table writes the same JSON that SwiftUI's drop destinations decode.
struct LibraryDragItem: Codable, Hashable, Transferable {
    enum Kind: String, Codable {
        case track, album, playlist, artist
    }

    var kind: Kind
    var id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .discodromeItem)
    }
}
