import DiscodromeCore
import SwiftUI

/// The bottom bar: the device, how its card is used, what's being copied. Songs dropped here
/// are copied to it.
struct DeviceBar: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceManager.self) private var devices
    @Environment(TransferManager.self) private var transfers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var isTargeted = false

    var body: some View {
        HStack(spacing: 14) {
            if let device = devices.primaryDevice {
                connected(device)
            } else {
                DiscGlyph()
                    .frame(width: 38, height: 38)
                    .opacity(0.35)
                    .saturation(0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Device Connected")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Connect your SNOWSKY DISC with USB to see its storage and copy music to it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(3)
            }
        }
        // Plugging the DISC in is an event: its drawing springs into the bar.
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.3), value: devices.primaryDevice?.id)
        .dropDestination(for: LibraryDragItem.self) { items, _ in
            guard let device = devices.primaryDevice else { return false }
            model.copy(items, to: device)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder
    private func connected(_ device: Device) -> some View {
        let contents = devices.contents[device.id]
        let usage = contents?.usage ?? DeviceUsage(capacity: device.capacity, available: device.available)
        let pending = transfers.pendingBytes(on: device.id)
        let copying = transfers.isActive(on: device.id)

        Button {
            model.sidebarSelection = .device(device.id)
        } label: {
            DeviceIllustration(device: device, size: 40)
        }
        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
        .buttonStyle(.plain)
        .help("Show what's on “\(device.name)”")

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(device.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(device.details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                status(device, contents)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            CapacityBar(usage: usage, pending: pending)
                .frame(height: 11)
            CapacityLegend(usage: usage, pending: pending)
        }

        if copying {
            Button {
                transfers.cancelAll()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop copying")
        }
        Button {
            model.eject(device)
        } label: {
            Label("Eject", systemImage: "eject.fill")
        }
        .help("Eject “\(device.name)” (⌘E)")
        .disabled(copying)
    }

    @ViewBuilder
    private func status(_ device: Device, _ contents: DeviceContents?) -> some View {
        if let job = transfers.activeJob, job.deviceID == device.id {
            let progress = transfers.progress
            Text("Copying \(min(progress.done + 1, progress.total)) of \(progress.total) — \(job.track.title)")
        } else if let summary = transfers.summary {
            HStack(spacing: 4) {
                Text(summary)
                Button {
                    transfers.clearFinished()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
        } else if let contents, contents.isScanning {
            Text("Scanning… \(contents.scannedCount.formatted()) songs")
        } else if let contents {
            Text("\(contents.files.count.formatted()) songs")
        }
    }
}

extension Device {
    /// "SNOWSKY DISC · exFAT · 128 GB" — without repeating the name when the card is called
    /// after the player.
    var details: String {
        var parts: [String] = []
        if hardwareName.caseInsensitiveCompare(name) != .orderedSame { parts.append(hardwareName) }
        parts.append(fileSystem)
        parts.append(Formatting.bytes(capacity))
        return parts.joined(separator: " · ")
    }
}

/// How the card is used, iPod-style: music by quality, everything else, free space, and — while
/// copying — the part that's about to be filled, in red if it won't fit.
struct CapacityBar: View {
    let usage: DeviceUsage
    let pending: Int64

    struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }

    static func segments(_ usage: DeviceUsage) -> [Segment] {
        [
            Segment(id: "hires", label: "Hi-Res", bytes: usage.hiRes, color: .purple),
            Segment(id: "lossless", label: "Lossless", bytes: usage.lossless, color: .blue),
            Segment(id: "lossy", label: "Lossy", bytes: usage.lossy, color: .teal),
            Segment(id: "other", label: "Other", bytes: usage.other + usage.lyricsAndArt, color: .gray),
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            let capacity = Double(max(usage.capacity, 1))
            let width = proxy.size.width
            let free = max(0, usage.available)
            let fits = pending <= free
            let pendingWidth = width * Double(min(pending, free)) / capacity

            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                HStack(spacing: 0) {
                    ForEach(Self.segments(usage).filter { $0.bytes > 0 }) { segment in
                        Rectangle()
                            .fill(segment.color.gradient)
                            .frame(width: max(1, width * Double(segment.bytes) / capacity))
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(.background.opacity(0.7)).frame(width: 1)
                            }
                            .help("\(segment.label): \(Formatting.bytes(segment.bytes))")
                    }
                    if pending > 0 {
                        StripedFill(color: fits ? .accentColor : .red)
                            .frame(width: max(2, fits ? pendingWidth : width * Double(free) / capacity))
                            .help(fits ? "To copy: \(Formatting.bytes(pending))" : "Doesn't fit: \(Formatting.bytes(pending - free)) too much")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Storage")
        .accessibilityValue("\(Formatting.bytes(usage.used)) used of \(Formatting.bytes(usage.capacity))")
    }
}

private struct StripedFill: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.35)))
            var stripes = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(stripes, with: .color(color.opacity(0.9)), lineWidth: 1.5)
        }
    }
}

struct CapacityLegend: View {
    let usage: DeviceUsage
    let pending: Int64

    var body: some View {
        HStack(spacing: 14) {
            ForEach(CapacityBar.segments(usage).filter { $0.bytes > 0 }) { segment in
                item(segment.label, segment.bytes) {
                    Circle().fill(segment.color)
                }
            }
            if pending > 0 {
                item("To Copy", pending) {
                    Circle().fill(pending <= usage.available ? Color.accentColor : .red)
                }
            }
            Spacer(minLength: 8)
            Text("\(Formatting.bytes(max(0, usage.available - pending))) Free")
                .foregroundStyle(pending > usage.available ? .red : .secondary)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private func item(_ label: String, _ bytes: Int64, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 4) {
            swatch().frame(width: 7, height: 7)
            Text(label)
            Text(Formatting.bytes(bytes)).foregroundStyle(.secondary)
        }
    }
}

/// The DISC as the app draws it, with the cover of what's playing — or of the last album copied to
/// it — on its screen. Other cards get a plain card symbol.
struct DeviceIllustration: View {
    let device: Device
    let size: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(TransferManager.self) private var transfers
    @ViewState private var artwork: NSImage?

    private var coverID: String? {
        if let track = player.currentTrack, let id = model.artworkID(for: track) { return id }
        return transfers.jobs.last { $0.deviceID == device.id && $0.phase == .done }?.track.coverArtID
    }

    var body: some View {
        Group {
            if device.isDISC {
                DiscGlyph(isSpinning: transfers.isActive(on: device.id), artwork: artwork, isPlaying: player.state.status == .playing)
            } else {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: size * 0.62))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: coverID) {
            guard let coverID else {
                artwork = nil
                return
            }
            artwork = await ArtworkLoader.shared.image(coverID, size: 240)
        }
    }
}

/// A drawing of the SNOWSKY DISC: a dark square body, a round screen, buttons on the right edge.
/// Like the player's own display, the screen shows a cover as a disc that turns slowly while music
/// plays; while songs are written to the card, a ring of light circles the screen.
struct DiscGlyph: View {
    var isSpinning = false
    var artwork: NSImage? = nil
    var isPlaying = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = !reduceMotion && (isSpinning || (isPlaying && artwork != nil))
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            Canvas { gc, size in
                let seconds = context.date.timeIntervalSinceReferenceDate
                let side = min(size.width, size.height)
                let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
                let body = CGRect(x: origin.x + side * 0.04, y: origin.y + side * 0.02, width: side * 0.9, height: side * 0.96)
                let bodyPath = Path(roundedRect: body, cornerRadius: side * 0.2, style: .continuous)
                gc.fill(bodyPath, with: .linearGradient(
                    Gradient(colors: [Color(white: 0.42), Color(white: 0.24), Color(white: 0.15)]),
                    startPoint: CGPoint(x: body.minX, y: body.minY), endPoint: CGPoint(x: body.maxX, y: body.maxY)))
                gc.stroke(bodyPath, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.5), .white.opacity(0.06)]),
                    startPoint: CGPoint(x: body.midX, y: body.minY), endPoint: CGPoint(x: body.midX, y: body.maxY)),
                    lineWidth: max(0.5, side * 0.02))

                // Buttons along the right edge.
                for (index, length) in [0.14, 0.1, 0.1].enumerated() {
                    let y = body.minY + side * (0.22 + Double(index) * 0.2)
                    let button = CGRect(x: body.maxX - side * 0.005, y: y, width: side * 0.045, height: side * length)
                    gc.fill(Path(roundedRect: button, cornerRadius: side * 0.02), with: .color(Color(white: 0.34)))
                }

                // The round screen in a thin bezel.
                let diameter = side * 0.7
                let screen = CGRect(x: body.midX - diameter / 2, y: body.midY - diameter / 2 + side * 0.03, width: diameter, height: diameter)
                let center = CGPoint(x: screen.midX, y: screen.midY)
                gc.fill(Path(ellipseIn: screen.insetBy(dx: -side * 0.018, dy: -side * 0.018)), with: .color(Color(white: 0.07)))
                gc.fill(Path(ellipseIn: screen), with: .color(.black))

                if let artwork, side >= 28 {
                    let disc = screen.insetBy(dx: diameter * 0.03, dy: diameter * 0.03)
                    var cover = gc
                    cover.clip(to: Path(ellipseIn: disc))
                    if isPlaying && !reduceMotion {
                        cover.translateBy(x: center.x, y: center.y)
                        cover.rotate(by: .degrees(seconds.truncatingRemainder(dividingBy: 16) / 16 * 360))
                        cover.translateBy(x: -center.x, y: -center.y)
                    }
                    // Fill the disc without stretching covers that aren't square.
                    let imageSize = artwork.size
                    let scale = imageSize.width > 0 && imageSize.height > 0
                        ? max(disc.width / imageSize.width, disc.height / imageSize.height) : 1
                    let drawn = imageSize.width > 0 && imageSize.height > 0
                        ? CGRect(x: disc.midX - imageSize.width * scale / 2, y: disc.midY - imageSize.height * scale / 2,
                                 width: imageSize.width * scale, height: imageSize.height * scale)
                        : disc
                    cover.draw(cover.resolve(Image(nsImage: artwork)), in: drawn)
                    // Faint grooves and a spindle hole make the cover read as a disc.
                    for ring in [0.34, 0.24] {
                        let r = diameter * ring
                        gc.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                                  with: .color(.black.opacity(0.16)), lineWidth: max(0.4, side * 0.008))
                    }
                    let hole = diameter * 0.075
                    let holeRect = CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2)
                    gc.fill(Path(ellipseIn: holeRect), with: .color(Color(white: 0.1)))
                    gc.stroke(Path(ellipseIn: holeRect), with: .color(.white.opacity(0.35)), lineWidth: max(0.4, side * 0.01))
                } else {
                    for ring in [0.36, 0.27] {
                        let r = diameter * ring
                        gc.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                                  with: .color(.white.opacity(0.18)), lineWidth: max(0.4, side * 0.01))
                    }
                    let hub = diameter * 0.08
                    gc.fill(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)), with: .color(.white.opacity(0.55)))
                    if !isSpinning {
                        var sheen = Path()
                        sheen.addArc(center: center, radius: diameter * 0.32, startAngle: .degrees(29), endAngle: .degrees(99), clockwise: false)
                        gc.stroke(sheen, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: max(0.8, side * 0.05), lineCap: .round))
                    }
                }

                // Glass: a soft reflection over the upper part of the screen.
                var glass = gc
                glass.clip(to: Path(ellipseIn: screen))
                glass.fill(Path(ellipseIn: CGRect(x: screen.minX - diameter * 0.2, y: screen.minY - diameter * 0.5, width: diameter * 1.2, height: diameter * 0.95)),
                           with: .linearGradient(Gradient(colors: [.white.opacity(0.16), .white.opacity(0)]),
                                                 startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.midX, y: screen.midY)))

                if isSpinning {
                    let start = Angle.degrees(reduceMotion ? 20 : seconds.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360)
                    var ring = Path()
                    ring.addArc(center: center, radius: diameter / 2 + side * 0.004, startAngle: start, endAngle: start + .degrees(80), clockwise: false)
                    gc.stroke(ring, with: .color(.accentColor), style: StrokeStyle(lineWidth: max(1, side * 0.032), lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
