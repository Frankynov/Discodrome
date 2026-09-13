import Foundation

/// A song still arriving from the network. It can be decoded as far as it has downloaded; a
/// file opened earlier doesn't see bytes written later, so the player reopens it as more arrives.
public protocol GrowingAudioFile: AnyObject, Sendable {
    /// Where the bytes are now: the partial file while downloading, the finished one after.
    var currentURL: URL { get }
    var isComplete: Bool { get }
    var failure: Error? { get }
    /// Whether, judging by its size, the download holds the audio up to `frame` of `length`.
    func probablyHas(frame: Int64, of length: Int64) -> Bool
    /// Runs `handler`, on an arbitrary thread, when more data has arrived or the download ended.
    func observe(_ handler: @escaping @Sendable () -> Void)
}

/// Where to read a track from: a complete file, or one still downloading.
public struct PlayableSource: Sendable {
    public let url: URL
    public let growing: GrowingAudioFile?

    public init(url: URL, growing: GrowingAudioFile? = nil) {
        self.url = url
        self.growing = growing
    }
}
