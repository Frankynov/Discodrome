import DiscodromeCore
import SwiftUI

/// Narrows the library to what is, or isn't yet, on the connected device.
enum DeviceFilter: String, CaseIterable, Identifiable {
    case all, onDevice, notOnDevice

    var id: Self { self }

    func label(isDISC: Bool) -> String {
        let name = isDISC ? "DISC" : "Device"
        switch self {
        case .all: return "All"
        case .onDevice: return "On \(name)"
        case .notOnDevice: return "Not on \(name)"
        }
    }

    /// An album counts as on the device when every one of its songs is: one only partly copied still
    /// has songs to copy, so it's listed as not on it.
    @MainActor
    func albums(_ albums: [Album], library: LibraryStore, devices: DeviceManager) -> [Album] {
        guard self != .all else { return albums }
        return albums.filter { album in
            var complete = false
            if case (.complete, _, _)? = AlbumDevicePresence.of(album, library: library, devices: devices) { complete = true }
            return complete == (self == .onDevice)
        }
    }

    @MainActor
    func tracks(_ tracks: [Track], devices: DeviceManager) -> [Track] {
        guard self != .all, let device = devices.primaryDevice,
              let presence = devices.contents[device.id]?.match.presence else { return tracks }
        return tracks.filter { (presence[$0.id] != nil) == (self == .onDevice) }
    }
}

/// All / On DISC / Not on DISC, for the album and song pages' headers. Only while a device is
/// connected; usable once its songs have been recognised.
struct DeviceFilterPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        @Bindable var model = model
        if let device = devices.primaryDevice {
            Picker("Show", selection: $model.deviceFilter) {
                ForEach(DeviceFilter.allCases) { filter in
                    Text(filter.label(isDISC: device.isDISC)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(devices.contents[device.id]?.hasScanned != true)
            .help("Show everything, or only what is or isn't yet on “\(device.name)”")
        }
    }
}

/// What a filtered page shows when nothing matches.
struct DeviceFilterEmptyView: View {
    let filter: DeviceFilter
    let noun: String
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        let name = devices.primaryDevice?.name ?? "the device"
        if filter == .onDevice {
            ContentUnavailableView("No \(noun.capitalized) on “\(name)”", systemImage: "externaldrive",
                                   description: Text("Drag \(noun) onto the device in the sidebar to copy them."))
        } else {
            ContentUnavailableView("Everything Is on “\(name)”", systemImage: "checkmark.circle",
                                   description: Text("All the \(noun) here are already on the card."))
        }
    }
}
