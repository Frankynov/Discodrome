import DiscodromeCore
import Foundation
import Observation

enum Paths {
    /// DISCODROME_DATA_DIR redirects everything the app stores — used for test runs.
    private static let override = ProcessInfo.processInfo.environment["DISCODROME_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    static let applicationSupport = override?.appending(path: "Support", directoryHint: .isDirectory)
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Discodrome", directoryHint: .isDirectory)
    static let caches = override?.appending(path: "Caches", directoryHint: .isDirectory)
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Discodrome", directoryHint: .isDirectory)
}

/// Everything the Settings window edits, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static var preferencesFile: String {
        "~/Library/Preferences/\(Bundle.main.bundleIdentifier ?? "com.discodrome.app").plist"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Server address, user name and salted token — stored in plain text, see the warning in
    /// Settings ▸ Server.
    var credentials: ServerCredentials? {
        didSet { defaults.set(credentials.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.credentials) }
    }
    var musicFolder: String { didSet { defaults.set(musicFolder, forKey: Keys.musicFolder) } }
    var pathTemplate: String { didSet { defaults.set(pathTemplate, forKey: Keys.pathTemplate) } }
    var writeLyricsFiles: Bool { didSet { defaults.set(writeLyricsFiles, forKey: Keys.writeLyrics) } }
    var cleanUpBeforeEject: Bool { didSet { defaults.set(cleanUpBeforeEject, forKey: Keys.cleanUp) } }
    var cacheLimitGB: Int { didSet { defaults.set(cacheLimitGB, forKey: Keys.cacheLimit) } }
    var scrobble: Bool { didSet { defaults.set(scrobble, forKey: Keys.scrobble) } }
    var volume: Double { didSet { defaults.set(volume, forKey: Keys.volume) } }
    var repeatMode: RepeatMode { didSet { defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode) } }
    /// Volumes the user told us are a SNOWSKY DISC, by volume UUID.
    var discVolumeIDs: Set<String> { didSet { defaults.set(Array(discVolumeIDs), forKey: Keys.discVolumes) } }

    private enum Keys {
        static let credentials = "server.credentials"
        static let musicFolder = "device.musicFolder"
        static let pathTemplate = "device.pathTemplate"
        static let writeLyrics = "device.writeLyricsFiles"
        static let cleanUp = "device.cleanUpBeforeEject"
        static let cacheLimit = "playback.cacheLimitGB"
        static let scrobble = "playback.scrobble"
        static let volume = "playback.volume"
        static let repeatMode = "playback.repeatMode"
        static let discVolumes = "device.discVolumeIDs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        credentials = defaults.data(forKey: Keys.credentials).flatMap { try? JSONDecoder().decode(ServerCredentials.self, from: $0) }
        musicFolder = defaults.string(forKey: Keys.musicFolder) ?? "Music"
        pathTemplate = defaults.string(forKey: Keys.pathTemplate) ?? DevicePathBuilder.defaultTemplate
        writeLyricsFiles = defaults.object(forKey: Keys.writeLyrics) as? Bool ?? true
        cleanUpBeforeEject = defaults.object(forKey: Keys.cleanUp) as? Bool ?? true
        cacheLimitGB = defaults.object(forKey: Keys.cacheLimit) as? Int ?? 4
        scrobble = defaults.object(forKey: Keys.scrobble) as? Bool ?? true
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        repeatMode = defaults.string(forKey: Keys.repeatMode).flatMap(RepeatMode.init(rawValue:)) ?? .off
        discVolumeIDs = Set(defaults.stringArray(forKey: Keys.discVolumes) ?? [])
    }

    var pathBuilder: DevicePathBuilder {
        DevicePathBuilder(musicFolder: musicFolder, template: pathTemplate)
    }
}
