import DiscodromeCore
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    /// Room for the segmented tabs and their margins.
    static let widthForTabs: CGFloat = 250

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.inspectorTab {
            case .info: InfoPane()
            case .lyrics: LyricsPane()
            case .upNext: UpNextPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // In the inspector's part of the toolbar, level with the player's controls, so all three
        // columns start at the same height. Only while the inspector is open, as the tabs switch
        // what it shows.
        .toolbar {
            if model.inspectorFitsTabs {
                ToolbarItem(placement: .automatic) {
                    Picker("Inspector", selection: $model.inspectorTab) {
                        ForEach(InspectorTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }
}

// MARK: - Info

private struct InfoPane: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player

    var body: some View {
        let selection = model.selectedTracks
        if selection.count > 1 {
            SelectionSummary(tracks: selection)
        } else if let track = selection.first ?? player.currentTrack {
            TrackInfo(track: track, isNowPlaying: selection.isEmpty)
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select a song to see its details."))
        }
    }
}

private struct TrackInfo: View {
    let track: Track
    let isNowPlaying: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isNowPlaying {
                    Text("Now Playing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                ArtworkView(coverArtID: model.artworkID(for: track), pixelSize: 700, cornerRadius: 8)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(track.artist).foregroundStyle(.secondary)
                    Text(track.album).foregroundStyle(.secondary)
                }

                DeviceStatusBox(track: track)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    row("Format", track.codecName)
                    row("Sample Rate", track.sampleRate.map { "\(Track.kilohertz($0)) kHz" })
                    row("Bit Depth", track.bitDepth.flatMap { $0 > 0 ? "\($0)-bit" : nil })
                    row("Bit Rate", track.bitRate.flatMap { $0 > 0 ? "\($0.formatted()) kbps" : nil })
                    row("Channels", track.channels.map { $0 == 1 ? "Mono" : ($0 == 2 ? "Stereo" : "\($0)") })
                    row("Duration", Formatting.duration(track.duration))
                    row("Size", track.size.map(Formatting.bytes))
                    Divider().gridCellColumns(2)
                    row("Track", track.trackNumber.map(String.init))
                    row("Disc", track.discNumber.map(String.init))
                    row("Year", track.year.map(String.init))
                    row("Genre", track.genre)
                    row("Plays", track.playCount.map { $0.formatted() })
                    row("Added", track.created.map { $0.formatted(date: .abbreviated, time: .omitted) })
                    row(track.isServerTrack ? "Server Path" : "Location", track.path)
                }
                .font(.callout)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
    }
}

private struct DeviceStatusBox: View {
    let track: Track
    @Environment(AppModel.self) private var model
    @Environment(DeviceManager.self) private var devices
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        if track.isServerTrack, let device = devices.primaryDevice {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if let job = transfers.jobs.first(where: { $0.track.id == track.id && !$0.isFinished }) {
                        Label("Copying to “\(device.name)”", systemImage: "arrow.down.to.line")
                        if case .writing(let fraction) = job.phase {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    } else if let presence = devices.presence(of: track.id, on: device.id) {
                        Label(presence.isExact ? "On “\(device.name)”" : "Probably on “\(device.name)”", systemImage: "checkmark.circle.fill")
                        Text(presence.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                        if !presence.isExact {
                            Text("A song with the same tags is on the card.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([device.url.appending(path: presence.relativePath)])
                        }
                        .controlSize(.small)
                    } else {
                        Label("Not on “\(device.name)”", systemImage: "circle.dashed")
                            .foregroundStyle(.secondary)
                        Button {
                            model.copy([track], to: device)
                        } label: {
                            Label("Copy to “\(device.name)”", systemImage: "arrow.down.to.line")
                        }
                        .controlSize(.small)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SelectionSummary: View {
    let tracks: [Track]
    @Environment(AppModel.self) private var model
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        let size = tracks.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let duration = tracks.reduce(0) { $0 + $1.duration }
        let onDevice = tracks.filter { devices.presence(of: $0.id) != nil }.count
        VStack(alignment: .leading, spacing: 12) {
            Text("\(tracks.count) Songs Selected").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow { Text("Duration").foregroundStyle(.secondary); Text(Formatting.longDuration(duration)) }
                GridRow { Text("Size").foregroundStyle(.secondary); Text(Formatting.bytes(size)) }
                GridRow { Text("Formats").foregroundStyle(.secondary); Text(Set(tracks.map(\.codecName)).sorted().joined(separator: ", ")) }
                if let device = devices.primaryDevice {
                    GridRow { Text("On Device").foregroundStyle(.secondary); Text("\(onDevice) of \(tracks.count) on “\(device.name)”") }
                }
            }
            .font(.callout)
            HStack {
                Button { model.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                if let device = devices.primaryDevice, tracks.contains(where: \.isServerTrack) {
                    Button { model.copy(tracks, to: device) } label: { Label("Copy", systemImage: "arrow.down.to.line") }
                        .disabled(onDevice == tracks.count)
                }
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lyrics

private struct LyricsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @ViewState private var lyrics: Lyrics?
    @ViewState private var loadedTrackID: String?

    var body: some View {
        Group {
            if let track = player.currentTrack {
                if loadedTrackID != track.id {
                    ProgressView()
                } else if let lyrics, !lyrics.lines.isEmpty {
                    if lyrics.synced {
                        SyncedLyricsView(lyrics: lyrics)
                    } else {
                        ScrollView {
                            Text(lyrics.lines.map(\.text).joined(separator: "\n"))
                                .font(.system(size: 14))
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                        }
                    }
                } else {
                    ContentUnavailableView("No Lyrics", systemImage: "quote.bubble", description: Text("There are no lyrics for “\(track.title)”."))
                }
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "quote.bubble", description: Text("Lyrics for the current song appear here."))
            }
        }
        .task(id: player.currentTrack?.id) {
            guard let track = player.currentTrack else { return }
            let found = await model.lyrics(for: track)
            guard player.currentTrack?.id == track.id else { return }
            lyrics = found
            loadedTrackID = track.id
        }
    }
}

private struct SyncedLyricsView: View {
    let lyrics: Lyrics
    @Environment(PlayerController.self) private var player

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: player.state.status != .playing)) { _ in
            LyricsLines(lyrics: lyrics, current: lyrics.lineIndex(at: player.state.position())) { line in
                if let start = line.start { player.seek(to: start) }
            }
        }
    }
}

private struct LyricsLines: View {
    let lyrics: Lyrics
    let current: Int?
    let seek: (Lyrics.Line) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(index == current ? .primary : .tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { seek(line) }
                            .id(index)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 140)
            }
            .onChange(of: current) { _, index in
                guard let index else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.35))
                }
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.35)) }
            }
        }
    }
}

// MARK: - Up Next

private struct UpNextPane: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player

    var body: some View {
        let upcoming = player.upNext
        VStack(alignment: .leading, spacing: 0) {
            if let current = player.state.currentItem {
                Text("Now Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                QueueRow(track: current.track)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                Divider()
            }
            HStack(spacing: 10) {
                Text("Up Next").font(.headline)
                Spacer()
                Toggle(isOn: Binding(get: { player.isShuffled }, set: { _ in player.toggleShuffle() })) {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .help(player.isShuffled ? "Shuffle is on" : "Shuffle")
                Toggle(isOn: Binding(get: { player.state.repeatMode != .off }, set: { _ in player.cycleRepeatMode() })) {
                    Label("Repeat", systemImage: player.state.repeatMode == .one ? "repeat.1" : "repeat")
                }
                .help(RepeatMode.helpText(player.state.repeatMode))
                if !upcoming.isEmpty {
                    Button("Clear") { player.clearUpNext() }
                        .buttonStyle(.borderless)
                }
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if upcoming.isEmpty {
                ContentUnavailableView("Nothing Up Next", systemImage: "list.bullet", description: Text("Play an album or add songs to Up Next."))
            } else {
                List {
                    ForEach(Array(upcoming.enumerated()), id: \.element.id) { offset, item in
                        QueueRow(track: item.track)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                if let base = player.state.currentIndex { player.jump(to: base + 1 + offset) }
                            }
                            .contextMenu {
                                Button("Play Now", systemImage: "play") {
                                    if let base = player.state.currentIndex { player.jump(to: base + 1 + offset) }
                                }
                                Button("Remove from Up Next", systemImage: "minus.circle") { player.removeFromQueue([item.id]) }
                            }
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { offsets in player.removeFromQueue(Set(offsets.map { upcoming[$0].id })) }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct QueueRow: View {
    let track: Track
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 9) {
            ArtworkView(coverArtID: model.artworkID(for: track), pixelSize: 96, cornerRadius: 3)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12)).lineLimit(1)
                Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Formatting.duration(track.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}
