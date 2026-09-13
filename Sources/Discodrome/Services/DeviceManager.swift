import AppKit
import DiscodromeCore
import DiskArbitration
import Foundation
import Observation

/// What DiskArbitration knows about the hardware behind a volume.
struct DiskDescription {
    var vendor: String?
    var model: String?
    var protocolName: String?
    var volumeKind: String?
    var mediaName: String?

    init(volumeURL: URL) {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return }
        func string(_ key: CFString) -> String? {
            (description[key as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        vendor = string(kDADiskDescriptionDeviceVendorKey)
        model = string(kDADiskDescriptionDeviceModelKey)
        protocolName = string(kDADiskDescriptionDeviceProtocolKey)
        volumeKind = string(kDADiskDescriptionVolumeKindKey)
        mediaName = string(kDADiskDescriptionMediaNameKey)
    }

    var isDiskImage: Bool {
        protocolName == "Disk Image" || protocolName == "Virtual Interface" || (model ?? "").contains("Disk Image")
    }

    /// What the SNOWSKY DISC actually reports over USB — the generic Linux mass-storage gadget,
    /// shared with other Linux-based players, so it only counts alongside the DISC's own folder.
    var isLinuxStorageGadget: Bool {
        (vendor ?? "").caseInsensitiveCompare("Linux") == .orderedSame
            && (model ?? "").range(of: "File-Stor Gadget", options: .caseInsensitive) != nil
    }

    var looksLikeSnowsky: Bool {
        [vendor, model, mediaName].compactMap { $0?.lowercased() }.contains { $0.contains("snowsky") || $0.contains("fiio") }
    }
}

struct Device: Identifiable, Hashable, Sendable {
    /// Volume UUID — stable across reconnections — or the mount path when there is none.
    let id: String
    var name: String
    var url: URL
    var isDISC: Bool
    var hardwareName: String
    var fileSystem: String
    var capacity: Int64
    var available: Int64
    /// Allocation block (cluster) size: every file occupies at least one.
    var blockSize: Int64 = 262_144
}

/// Everything known about one connected device's card.
struct DeviceContents {
    var files: [DeviceFile] = []
    var tracks: [Track] = [] {
        didSet { tracksRevision += 1 }
    }
    private(set) var tracksRevision = 0
    var usage: DeviceUsage
    var clutter: [String] = []
    var match = DeviceMatcher.Result() {
        didSet { matchRevision += 1 }
    }
    /// Bumped on every change to `match`, so song lists refresh their device column cheaply.
    private(set) var matchRevision = 0
    var isScanning = false
    var scannedCount = 0
    var hasScanned = false
}

/// Watches for cards and players being mounted, scans them, and keeps track of which library
/// songs they already hold.
@MainActor @Observable
final class DeviceManager {
    private(set) var devices: [Device] = []
    private(set) var contents: [String: DeviceContents] = [:]
    var lastError: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var matchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let includeDiskImages = ProcessInfo.processInfo.environment["DISCODROME_INCLUDE_DISK_IMAGES"] != nil
    /// DISCODROME_FAKE_DEVICE=/some/folder presents that folder as a SNOWSKY DISC — for
    /// developing without the player plugged in.
    private let fakeDeviceFolder = ProcessInfo.processInfo.environment["DISCODROME_FAKE_DEVICE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    @ObservationIgnored private var fakeDeviceEjected = false
    private static let fakeDeviceID = "fake-device"
    /// DISCODROME_FAKE_DEVICE_CAPACITY_MB makes the fake card small enough for its usage to show.
    private static let fakeDeviceCapacity: Int64 = ProcessInfo.processInfo.environment["DISCODROME_FAKE_DEVICE_CAPACITY_MB"]
        .flatMap { Int64($0) }.map { $0 << 20 } ?? 128 << 30

    init(settings: AppSettings, library: LibraryStore) {
        self.settings = settings
        self.library = library
    }

    /// The device the bottom bar and drop targets use: the first DISC, else the first card.
    var primaryDevice: Device? {
        devices.first(where: \.isDISC) ?? devices.first
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
        refreshVolumes()
    }

    func presence(of trackID: String, on deviceID: String? = nil) -> DevicePresence? {
        guard let id = deviceID ?? primaryDevice?.id else { return nil }
        return contents[id]?.match.presence[trackID]
    }

    // MARK: Volumes

    func refreshVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
        ]
        var found: [Device] = []
        // With a fake device configured (development), real cards are left alone.
        let volumes = fakeDeviceFolder == nil
            ? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            : []
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false,
                  values.volumeIsInternal == false || values.volumeIsRemovable == true || values.volumeIsEjectable == true else { continue }
            let disk = DiskDescription(volumeURL: url)
            if disk.isDiskImage && !includeDiskImages { continue }
            let id = values.volumeUUIDString ?? url.path
            let kind = (disk.volumeKind ?? "").lowercased()
            let name = values.volumeName ?? url.lastPathComponent
            // The firmware keeps a CustomCover folder at the root of the card.
            let hasDISCFolder = FileManager.default.fileExists(atPath: url.appending(path: "CustomCover").path)
            let isDISC = disk.looksLikeSnowsky || settings.discVolumeIDs.contains(id) || name.uppercased().contains("SNOWSKY")
                || (disk.isLinuxStorageGadget && hasDISCFolder)
            // Players and memory cards use FAT; leave backup drives and the like alone.
            guard isDISC || kind == "msdos" || kind == "exfat" else { continue }
            found.append(Device(
                id: id,
                name: name,
                url: url,
                isDISC: isDISC,
                hardwareName: isDISC ? "SNOWSKY DISC" : ([disk.vendor, disk.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty ?? "Removable Card"),
                fileSystem: kind == "msdos" ? "FAT32" : (kind == "exfat" ? "exFAT" : kind),
                capacity: Int64(values.volumeTotalCapacity ?? 0),
                available: Int64(values.volumeAvailableCapacity ?? 0),
                blockSize: Self.blockSize(of: url)
            ))
        }

        if let folder = fakeDeviceFolder, !fakeDeviceEjected, FileManager.default.fileExists(atPath: folder.path) {
            found.append(Device(
                id: Self.fakeDeviceID, name: "SNOWSKY DISC", url: folder, isDISC: true, hardwareName: "SNOWSKY DISC",
                fileSystem: "exFAT", capacity: Self.fakeDeviceCapacity, available: Self.fakeDeviceCapacity - Self.folderSize(folder)
            ))
        }

        let previous = Set(devices.map(\.id))
        devices = found.sorted { ($0.isDISC ? 0 : 1, $0.name) < ($1.isDISC ? 0 : 1, $1.name) }
        for device in devices where !previous.contains(device.id) {
            deviceAppeared(device)
        }
        for id in previous where !devices.contains(where: { $0.id == id }) {
            contents[id] = nil
            matchTasks[id]?.cancel()
        }
    }

    func setIsDISC(_ isDISC: Bool, for device: Device) {
        if isDISC { settings.discVolumeIDs.insert(device.id) } else { settings.discVolumeIDs.remove(device.id) }
        refreshVolumes()
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index].isDISC = isDISC || DiskDescription(volumeURL: device.url).looksLikeSnowsky
            devices[index].hardwareName = devices[index].isDISC ? "SNOWSKY DISC" : "Removable Card"
        }
    }

    private func deviceAppeared(_ device: Device) {
        var initial = DeviceContents(usage: DeviceUsage(capacity: device.capacity, available: device.available))
        let manifest = Self.loadManifest(device.id)
        if !manifest.isEmpty {
            initial.files = manifest
            initial.tracks = manifest.map { $0.track(volumeRoot: device.url) }
        }
        contents[device.id] = initial
        rematch(device.id)
        scan(device)
    }

    static func blockSize(of volume: URL) -> Int64 {
        var info = statfs()
        guard statfs(volume.path, &info) == 0, info.f_bsize > 0 else { return 262_144 }
        return Int64(info.f_bsize)
    }

    private static func folderSize(_ folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    func refreshCapacity(_ deviceID: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        if deviceID == Self.fakeDeviceID {
            devices[index].available = Self.fakeDeviceCapacity - Self.folderSize(devices[index].url)
            contents[deviceID]?.usage.available = devices[index].available
            return
        }
        var url = devices[index].url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) else { return }
        devices[index].available = Int64(values.volumeAvailableCapacity ?? 0)
        devices[index].capacity = Int64(values.volumeTotalCapacity ?? 0)
        contents[deviceID]?.usage.available = devices[index].available
        contents[deviceID]?.usage.capacity = devices[index].capacity
    }

    // MARK: Scanning & matching

    func scan(_ device: Device) {
        guard contents[device.id]?.isScanning != true else { return }
        contents[device.id]?.isScanning = true
        contents[device.id]?.scannedCount = 0
        let known = Dictionary((contents[device.id]?.files ?? []).map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        let root = device.url
        let id = device.id
        let capacity = device.capacity
        let available = device.available
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DeviceScanner.scan(root: root, known: known, capacity: capacity, available: available) { count in
                    Task { @MainActor in self.contents[id]?.scannedCount = count }
                }
            }.value
            guard contents[id] != nil else { return }
            let tracks = await Task.detached { result.files.map { $0.track(volumeRoot: root) } }.value
            contents[id]?.files = result.files
            contents[id]?.tracks = tracks
            contents[id]?.usage = result.usage
            contents[id]?.clutter = result.clutter
            contents[id]?.isScanning = false
            contents[id]?.hasScanned = true
            rematch(id)
            saveManifest(id)
        }
    }

    /// Re-runs matching against the current library — after a scan, a copy, or a library sync.
    func rematch(_ deviceID: String) {
        guard let files = contents[deviceID]?.files else { return }
        let library = self.library.tracks
        matchTasks[deviceID]?.cancel()
        matchTasks[deviceID] = Task {
            let result = await Task.detached(priority: .userInitiated) {
                DeviceMatcher.match(library: library, device: files)
            }.value
            guard !Task.isCancelled else { return }
            contents[deviceID]?.match = result
        }
    }

    func rematchAll() {
        for device in devices { rematch(device.id) }
    }

    // MARK: Changes made by Discodrome

    func recordCopy(_ file: DeviceFile, of track: Track, on deviceID: String) {
        guard var entry = contents[deviceID], let device = devices.first(where: { $0.id == deviceID }) else { return }
        entry.files.removeAll { $0.relativePath == file.relativePath }
        entry.files.append(file)
        let deviceTrack = file.track(volumeRoot: device.url)
        entry.tracks.removeAll { $0.id == deviceTrack.id }
        entry.tracks.append(deviceTrack)
        if deviceTrack.isHiRes { entry.usage.hiRes += file.size }
        else if deviceTrack.isLossless { entry.usage.lossless += file.size }
        else { entry.usage.lossy += file.size }
        entry.match.presence[track.id] = .exact(file.relativePath)
        entry.match.trackForFile[file.relativePath] = track.id
        contents[deviceID] = entry
        refreshCapacity(deviceID)
        saveManifest(deviceID)
    }

    /// Deletes songs (and their lyrics sidecars) from the card.
    func delete(_ relativePaths: [String], from device: Device) {
        guard var entry = contents[device.id] else { return }
        let fileManager = FileManager.default
        var failures = 0
        for path in relativePaths {
            let url = device.url.appending(path: path)
            do {
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
                let lyrics = url.deletingPathExtension().appendingPathExtension("lrc")
                if fileManager.fileExists(atPath: lyrics.path) { try? fileManager.removeItem(at: lyrics) }
                Self.removeEmptyFolders(from: url.deletingLastPathComponent(), stoppingAt: device.url)
                if let file = entry.files.first(where: { $0.relativePath == path }) {
                    let track = file.track(volumeRoot: device.url)
                    if track.isHiRes { entry.usage.hiRes -= file.size }
                    else if track.isLossless { entry.usage.lossless -= file.size }
                    else { entry.usage.lossy -= file.size }
                }
                entry.files.removeAll { $0.relativePath == path }
                entry.tracks.removeAll { $0.id == "device:" + path }
            } catch {
                failures += 1
            }
        }
        contents[device.id] = entry
        if failures > 0 { lastError = "\(failures) file\(failures == 1 ? "" : "s") couldn't be deleted from \(device.name)." }
        refreshCapacity(device.id)
        rematch(device.id)
        saveManifest(device.id)
    }

    private static func removeEmptyFolders(from folder: URL, stoppingAt root: URL) {
        var current = folder.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while current.path.count > rootPath.count, current.path.hasPrefix(rootPath) {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? ["?"]
            // A folder holding only Finder or AppleDouble debris counts as empty.
            guard children.allSatisfy({ $0 == ".DS_Store" || $0.hasPrefix("._") }) else { return }
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    func cleanUp(_ device: Device) -> Int {
        guard let clutter = contents[device.id]?.clutter, !clutter.isEmpty else { return 0 }
        let removed = DeviceScanner.removeClutter(clutter, root: device.url)
        contents[device.id]?.clutter = []
        refreshCapacity(device.id)
        return removed
    }

    func eject(_ device: Device) async {
        if settings.cleanUpBeforeEject { _ = cleanUp(device) }
        await flushManifest(device.id)
        if device.id == Self.fakeDeviceID {
            fakeDeviceEjected = true
            refreshVolumes()
            return
        }
        do {
            try await FileManager.default.unmountVolume(at: device.url, options: [.allPartitionsAndEjectDisk, .withoutUI])
            refreshVolumes()
        } catch {
            lastError = "\(device.name) couldn't be ejected: \(error.localizedDescription)"
        }
    }

    // MARK: Manifest

    /// Tags already read and which server song each copy came from, per volume — so a
    /// reconnect doesn't re-read every header over USB.
    private nonisolated static func manifestURL(_ id: String) -> URL {
        let safe = id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return Paths.applicationSupport.appending(path: "Devices/\(safe).json")
    }

    private static func loadManifest(_ id: String) -> [DeviceFile] {
        guard let data = try? Data(contentsOf: manifestURL(id)) else { return [] }
        return (try? JSONDecoder().decode([DeviceFile].self, from: data)) ?? []
    }

    private func saveManifest(_ id: String) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await flushManifest(id)
        }
    }

    private func flushManifest(_ id: String) async {
        guard let files = contents[id]?.files else { return }
        await Task.detached(priority: .utility) {
            let url = Self.manifestURL(id)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(files) { try? data.write(to: url, options: .atomic) }
        }.value
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
