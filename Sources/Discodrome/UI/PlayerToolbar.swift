import DiscodromeCore
import SwiftUI

/// Transport on the leading side, the now-playing display in the middle, volume and the
/// inspector on the trailing side. Every button is a Label, so the toolbar reads correctly in
/// Icon and Text mode; Shuffle and Repeat can be added with View ▸ Customize Toolbar.
struct PlayerToolbarContent: CustomizableToolbarContent {
    let player: PlayerController
    let isPlaying: Bool
    let hasQueue: Bool
    let isShuffled: Bool
    let repeatMode: RepeatMode
    @Binding var showInspector: Bool

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "previous", placement: .navigation) {
            Button { player.previous() } label: {
                Label("Previous", systemImage: "backward.fill")
            }
            .help("Previous (⌘←)")
            .disabled(!hasQueue)
        }
        ToolbarItem(id: "playPause", placement: .navigation) {
            Button { player.togglePlayPause() } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .help(isPlaying ? "Pause (Space)" : "Play (Space)")
            .disabled(!hasQueue)
        }
        ToolbarItem(id: "next", placement: .navigation) {
            Button { player.next() } label: {
                Label("Next", systemImage: "forward.fill")
            }
            .help("Next (⌘→)")
            .disabled(!hasQueue)
        }

        ToolbarItem(id: "nowPlaying", placement: .principal) {
            NowPlayingDisplay()
        }

        ToolbarItem(id: "shuffle", placement: .primaryAction, showsByDefault: false) {
            Toggle(isOn: Binding(get: { isShuffled }, set: { _ in player.toggleShuffle() })) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .help(isShuffled ? "Shuffle is on" : "Shuffle")
        }
        ToolbarItem(id: "repeat", placement: .primaryAction, showsByDefault: false) {
            Toggle(isOn: Binding(get: { repeatMode != .off }, set: { _ in player.cycleRepeatMode() })) {
                Label(repeatMode == .one ? "Repeat One" : "Repeat", systemImage: repeatMode == .one ? "repeat.1" : "repeat")
            }
            .help(RepeatMode.helpText(repeatMode))
        }
        ToolbarItem(id: "volume", placement: .primaryAction) {
            VolumeControl()
        }
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide info, lyrics and Up Next (⌥⌘I)")
        }
    }
}

extension RepeatMode {
    static func helpText(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: return "Repeat"
        case .all: return "Repeating all — click to repeat one"
        case .one: return "Repeating one — click to turn off"
        }
    }
}

struct NowPlayingDisplay: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var model
    @ViewState private var isHovering = false

    var body: some View {
        let track = player.currentTrack
        HStack(spacing: 9) {
            ArtworkView(coverArtID: track.flatMap(model.artworkID(for:)), pixelSize: 96, cornerRadius: 4)
                .frame(width: 34, height: 34)
                .opacity(track == nil ? 0.5 : 1)

            VStack(spacing: 0) {
                Text(track?.title ?? "Discodrome")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                PositionRow(track: track, isHovering: isHovering)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, 3)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .frame(minWidth: 250, idealWidth: 400, maxWidth: 540)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu {
            if track != nil {
                Button("Go to Current Song", systemImage: "arrow.right.circle") { model.goToCurrentSong() }
                Button("Show Lyrics", systemImage: "quote.bubble") {
                    model.showInspector = true
                    model.inspectorTab = .lyrics
                }
            }
        }
    }
}

/// Elapsed time, artist and album, remaining time — and a thin scrub bar beneath. Redraws
/// only itself, and only while playing.
private struct PositionRow: View {
    let track: Track?
    let isHovering: Bool
    @Environment(PlayerController.self) private var player
    @ViewState private var dragFraction: Double?

    var body: some View {
        let state = player.state
        let subtitle = track.map { "\($0.artist) — \($0.album)" } ?? "Nothing playing"
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: state.status != .playing || dragFraction != nil)) { _ in
            let duration = state.duration
            let position = dragFraction.map { $0 * duration } ?? state.position()
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0

            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Group {
                        if state.status == .loading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(track == nil ? "" : Formatting.duration(position))
                        }
                    }
                    .frame(width: 38, alignment: .leading)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)

                    Text(track == nil ? "" : "-" + Formatting.duration(max(0, duration - position)))
                        .frame(width: 38, alignment: .trailing)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)

                ScrubTrack(fraction: fraction, isEmphasized: isHovering || dragFraction != nil)
                    .frame(height: 6)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0, track != nil else { return }
                                dragFraction = min(1, max(0, value.location.x / max(1, value.startLocation.x.isFinite ? scrubWidth : 1)))
                            }
                            .onEnded { _ in
                                if let dragFraction, duration > 0 { player.seek(to: dragFraction * duration) }
                                dragFraction = nil
                            }
                    )
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { scrubWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in scrubWidth = width }
                    })
                    .opacity(track == nil ? 0 : 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(track == nil ? "Nothing playing" : "\(Formatting.duration(state.position())) of \(Formatting.duration(state.duration))")
        .accessibilityAdjustableAction { direction in
            player.skip(by: direction == .increment ? 10 : -10)
        }
    }

    @ViewState private var scrubWidth: CGFloat = 1
}

private struct ScrubTrack: View {
    let fraction: Double
    let isEmphasized: Bool

    var body: some View {
        GeometryReader { proxy in
            let height: CGFloat = isEmphasized ? 4 : 2
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.secondary)
                    .frame(width: max(height, proxy.size.width * fraction))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: isEmphasized)
        }
    }
}

struct VolumeControl: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 5) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $player.volume, in: 0...1)
                .controlSize(.mini)
                .frame(width: 72)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .help("Volume (⌘↑ ⌘↓)")
    }
}
