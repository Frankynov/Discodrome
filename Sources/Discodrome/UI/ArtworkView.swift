import AppKit
import DiscodromeCore
import SwiftUI

struct ArtworkView: View {
    let coverArtID: String?
    let pixelSize: Int
    let cornerRadius: CGFloat

    @ViewState private var image: NSImage?

    init(coverArtID: String?, pixelSize: Int = 300, cornerRadius: CGFloat = 6) {
        self.coverArtID = coverArtID
        self.pixelSize = pixelSize
        self.cornerRadius = cornerRadius
        _image = State(initialValue: ArtworkLoader.shared.cachedImage(coverArtID, size: pixelSize))
    }

    var body: some View {
        // The square is set by a clear view; the cover only overlays it. Laid out directly, a
        // non-square cover scaled to fill would widen the view and spill onto its neighbours.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: max(9, CGFloat(pixelSize) / 12), weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        .task(id: "\(coverArtID ?? "-")@\(pixelSize)") {
            guard let coverArtID else {
                image = nil
                return
            }
            if let cached = ArtworkLoader.shared.cachedImage(coverArtID, size: pixelSize) {
                image = cached
                return
            }
            image = nil
            image = await ArtworkLoader.shared.image(coverArtID, size: pixelSize)
        }
    }
}
