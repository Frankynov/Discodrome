import AppKit
import DiscodromeCore
import ImageIO

/// Cover art from the server: memory cache, then disk cache, then network — decoded to the
/// requested size off the main thread so scrolling a wall of albums stays smooth.
@MainActor
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private let memory = NSCache<NSString, NSImage>()
    private var client: SubsonicClient?
    private var directory: URL?
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        memory.countLimit = 800
    }

    func configure(_ client: SubsonicClient?) {
        self.client = client
        memory.removeAllObjects()
        inFlight.removeAll()
        directory = client.map { Paths.caches.appending(path: "Artwork/\($0.credentials.cacheKey)", directoryHint: .isDirectory) }
    }

    private func key(_ id: String, _ size: Int) -> String { "\(id)@\(size)" }

    func cachedImage(_ id: String?, size: Int) -> NSImage? {
        guard let id else { return nil }
        return memory.object(forKey: key(id, size) as NSString)
    }

    func image(_ id: String, size: Int) async -> NSImage? {
        let cacheKey = key(id, size)
        if let hit = memory.object(forKey: cacheKey as NSString) { return hit }
        if let running = inFlight[cacheKey] { return await running.value }
        guard let client, let directory else { return nil }

        let remote = client.coverArtURL(id: id, size: size)
        let safeName = id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        let file = directory.appending(path: "\(safeName)-\(size).img")
        let task = Task<NSImage?, Never> {
            let decoded = await Task.detached(priority: .utility) { () -> DecodedImage? in
                if let data = try? Data(contentsOf: file), let image = DecodedImage(data: data, maxPixelSize: size) {
                    return image
                }
                guard let (data, response) = try? await URLSession.shared.data(from: remote),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = DecodedImage(data: data, maxPixelSize: size) else { return nil }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file)
                return image
            }.value
            return decoded.map { NSImage(cgImage: $0.cgImage, size: NSSize(width: $0.cgImage.width, height: $0.cgImage.height)) }
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image { memory.setObject(image, forKey: cacheKey as NSString) }
        return image
    }
}

/// A decoded, downsampled image that can cross from the decoding task to the main actor.
struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage

    init?(data: Data, maxPixelSize: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cgImage = image
    }
}
