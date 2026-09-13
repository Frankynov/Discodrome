import DiscodromeCore
import SwiftUI

struct DiscodromeCommands: Commands {
    let model: AppModel

    private var deviceName: String {
        model.devices.primaryDevice.map { "“\($0.name)”" } ?? "Device"
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Refresh Library") {
                Task { await model.library.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.library.client == nil || model.library.isSyncing)

            Divider()

            Button("Copy Selection to \(deviceName)") {
                model.copy(model.selectedTracks)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.devices.primaryDevice == nil || !model.selectedTracks.contains(where: \.isServerTrack))

            Button("Eject \(deviceName)") {
                if let device = model.devices.primaryDevice { model.eject(device) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.devices.primaryDevice == nil)
        }

        CommandMenu("Controls") {
            Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayPause() }
                .disabled(model.player.state.items.isEmpty)
            Button("Next") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(model.player.currentTrack == nil)
            Button("Previous") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(model.player.currentTrack == nil)

            Divider()

            Button("Go to Current Song") { model.goToCurrentSong() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.player.currentTrack == nil)

            Divider()

            Button("Increase Volume") { model.player.adjustVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { model.player.adjustVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Toggle("Shuffle", isOn: Binding(get: { model.player.isShuffled }, set: { _ in model.player.toggleShuffle() }))
            Picker("Repeat", selection: Binding(get: { model.player.state.repeatMode }, set: { model.player.setRepeatMode($0) })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
        }

        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Show Info") { model.showInfo() }
                .keyboardShortcut("i", modifiers: .command)
            Button("Show Lyrics") {
                model.showInspector = true
                model.inspectorTab = .lyrics
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Show Up Next") {
                model.showInspector = true
                model.inspectorTab = .upNext
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
        }
    }
}
