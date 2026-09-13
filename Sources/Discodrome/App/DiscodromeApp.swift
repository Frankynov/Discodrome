import AppKit
import DiscodromeCore
import SwiftUI

@main
struct DiscodromeApp: App {
    @ViewState private var model = AppModel()

    var body: some Scene {
        Window("Discodrome", id: "main") {
            MainWindow()
                .environmentObjects(model)
                .frame(minWidth: 940, minHeight: 580)
        }
        .defaultSize(width: 1320, height: 840)
        // A regular-height toolbar without the title: pages show their own titles, and the
        // now-playing display needs the room.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { DiscodromeCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObjects(model)
        }
    }
}

extension View {
    func environmentObjects(_ model: AppModel) -> some View {
        environment(model)
            .environment(model.settings)
            .environment(model.library)
            .environment(model.player)
            .environment(model.devices)
            .environment(model.transfers)
    }
}
