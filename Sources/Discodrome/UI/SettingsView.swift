import DiscodromeCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ServerSettingsView()
                .tabItem { Label("Server", systemImage: "server.rack") }
            DeviceSettingsView()
                .tabItem { Label("Device", systemImage: "externaldrive") }
            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.circle") }
        }
        .frame(width: 560)
    }
}

private struct ServerSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @ViewState private var address = ""
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var status: Status = .idle

    enum Status: Equatable {
        case idle, testing, success(String), failure(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address, prompt: Text("http://navidrome.local:4533"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password, prompt: Text(settings.credentials == nil ? "Required" : "Leave empty to keep the current one"))
            } header: {
                Text("Navidrome or another Subsonic server")
            } footer: {
                switch status {
                case .idle:
                    if let info = library.serverInfo {
                        Label("Connected to \(info.displayName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                case .testing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Connecting…")
                    }
                    .foregroundStyle(.secondary)
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                case .failure(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    if settings.credentials != nil {
                        Button("Disconnect", role: .destructive) {
                            settings.credentials = nil
                            model.applyServerSettings()
                            password = ""
                            status = .idle
                        }
                    }
                    Spacer()
                    Button("Connect") {
                        Task { await connect() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.isEmpty || username.isEmpty || status == .testing)
                }
            }

            Section {
                Label {
                    Text("The address, your username and a salted token made from your password are saved unencrypted in \(AppSettings.preferencesFile). Anyone who can read your files can use them to sign in to this server.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            address = settings.credentials?.serverURL.absoluteString ?? ""
            username = settings.credentials?.username ?? ""
        }
    }

    private func connect() async {
        guard let url = ServerCredentials.normalizedServerURL(address) else {
            status = .failure("Enter the server's address, such as http://192.168.1.20:4533.")
            return
        }
        let credentials: ServerCredentials
        if password.isEmpty, let existing = settings.credentials, existing.serverURL == url, existing.username == username {
            credentials = existing
        } else {
            guard !password.isEmpty else {
                status = .failure("Enter your password.")
                return
            }
            credentials = ServerCredentials(serverURL: url, username: username, password: password)
        }
        status = .testing
        do {
            let info = try await SubsonicClient(credentials: credentials).ping()
            settings.credentials = credentials
            password = ""
            address = url.absoluteString
            model.applyServerSettings()
            status = .success("Connected to \(info.displayName).")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}

private struct DeviceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    private var example: String {
        let track = Track(id: "example", origin: .server, title: "Harbour Lights", artist: "Glass Rivers", albumArtist: "Glass Rivers",
                          album: "Northbound", trackNumber: 7, discNumber: 1, year: 2021, genre: "Indie", suffix: "flac")
        return settings.pathBuilder.relativePath(for: track, suffix: "flac", discCount: 1)
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("Music folder", text: $settings.musicFolder, prompt: Text("Music"))
                TextField("Folders and file name", text: $settings.pathTemplate)
                    .font(.body.monospaced())
                LabeledContent("Example") {
                    Text(example)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("{albumartist} {artist} {album} {year} {genre} {disc} {track} {title}")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Default") {
                        settings.musicFolder = "Music"
                        settings.pathTemplate = DevicePathBuilder.defaultTemplate
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Where songs go on the card")
            } footer: {
                Text("The SNOWSKY DISC has no playlists — you browse it by folder, so this layout is what you'll see on the player.")
            }

            Section("Copying") {
                Toggle(isOn: $settings.writeLyricsFiles) {
                    Text("Copy synced lyrics as .lrc files")
                    Text("The DISC shows lyrics from an .lrc file next to the song (firmware 1.65 or later).")
                }
                Toggle(isOn: $settings.cleanUpBeforeEject) {
                    Text("Remove macOS hidden files when ejecting")
                    Text("Finder leaves “._” files on memory cards, which the DISC lists as unplayable songs.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @ViewState private var cacheSize: Int64?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Keep downloaded songs up to", selection: $settings.cacheLimitGB) {
                    ForEach([1, 2, 4, 8, 16, 32], id: \.self) { Text("\($0) GB").tag($0) }
                }
                LabeledContent("In use") {
                    Text(cacheSize.map(Formatting.bytes) ?? "…")
                }
                HStack {
                    Spacer()
                    Button("Remove Downloaded Songs") {
                        model.player.provider.serverProvider?.clear()
                        Task { await refreshSize() }
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Songs are fetched in full before they play, which is what makes playback gapless. Copying to the device reuses them.")
            }

            Section("Server") {
                Toggle(isOn: $settings.scrobble) {
                    Text("Report plays to the server")
                    Text("Updates play counts and “recently played” in Navidrome.")
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshSize() }
        .onChange(of: settings.cacheLimitGB) {
            model.player.setServer(model.library.client)
        }
    }

    private func refreshSize() async {
        let provider = model.player.provider.serverProvider
        cacheSize = await Task.detached { provider?.cacheSize() ?? 0 }.value
    }
}
