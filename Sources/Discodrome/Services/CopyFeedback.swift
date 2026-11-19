import AppKit
import UserNotifications

/// What a run of copies came to, for the notification at its end.
struct CopyReport: Sendable {
    let deviceID: String
    let deviceName: String
    /// "It Goes On — Westside Cowboy" for one copy, "3 copies" for several.
    let title: String
    let copied: Int
    let failed: Int
    let bytes: Int64
}

/// A notification when a copy ends while Discodrome is in the background. Clicking it brings the
/// app forward on the device's Transfers.
@MainActor
final class CopyNotifier {
    private let delegate = NotificationDelegate()
    /// Snapshot runs log what they would post instead: no permission prompt on the test Mac.
    private let isRehearsal = ProcessInfo.processInfo.environment["DISCODROME_SNAPSHOTS"] != nil
    /// Only inside an app bundle: the notification centre needs a bundle identifier.
    private var center: UNUserNotificationCenter? {
        guard !isRehearsal, Bundle.main.bundlePath.hasSuffix(".app"), Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
    private var askedPermission = false

    init(open: @escaping @MainActor (String) -> Void) {
        delegate.open = open
        center?.delegate = delegate
    }

    /// Asked when the first copy starts rather than at launch, when it's clear what it's for.
    func copyStarted() {
        guard !askedPermission, let center else { return }
        askedPermission = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func copyFinished(_ report: CopyReport) {
        guard report.copied + report.failed > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = report.failed == 0 ? "Copied to “\(report.deviceName)”" : "Copy to “\(report.deviceName)” finished"
        content.subtitle = report.title
        var body = "\(report.copied) song\(report.copied == 1 ? "" : "s")"
        if report.bytes > 0, report.copied > 0 { body += ", \(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file))" }
        if report.failed > 0 { body += " — \(report.failed) couldn't be copied" }
        content.body = body + "."
        content.userInfo = ["deviceID": report.deviceID]
        if isRehearsal {
            FileHandle.standardError.write(Data("notification: \(content.title) | \(content.subtitle) | \(content.body)\n".utf8))
            return
        }
        // In front, the Transfers list and the bar already say it.
        guard !NSApp.isActive, let center else { return }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Called by the notification centre on its own queue: nothing here may assume the main actor.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var open: (@MainActor (String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let deviceID = response.notification.request.content.userInfo["deviceID"] as? String else { return }
        let open = open
        await MainActor.run {
            NSApp.activate()
            open?(deviceID)
        }
    }
}

/// The copy's progress as a bar across the Dock icon, as Finder and Safari show theirs.
@MainActor
final class DockProgress {
    private var view: DockProgressView?
    private var shown = -1.0

    /// `nil` takes the bar away.
    func show(_ fraction: Double?) {
        let tile = NSApp.dockTile
        guard let fraction else {
            guard view != nil else { return }
            view = nil
            shown = -1
            tile.contentView = nil
            tile.display()
            return
        }
        // Whole percents: the Dock redraws the tile on every display().
        let rounded = (min(max(fraction, 0), 1) * 100).rounded() / 100
        guard rounded != shown else { return }
        shown = rounded
        if view == nil {
            let fresh = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            tile.contentView = fresh
            view = fresh
        }
        view?.fraction = rounded
        tile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        // Inside the icon's square (the middle 80 % of the tile), clear of its bottom edge.
        let height = (bounds.height * 0.09).rounded()
        let track = NSRect(x: bounds.width * 0.18, y: bounds.height * 0.17, width: bounds.width * 0.64, height: height)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        trackPath.fill()
        NSColor.white.withAlphaComponent(0.75).setStroke()
        trackPath.lineWidth = 1.5
        trackPath.stroke()
        let inset = track.insetBy(dx: 3, dy: 3)
        guard fraction > 0 else { return }
        let filled = NSRect(x: inset.minX, y: inset.minY, width: max(inset.height, inset.width * fraction), height: inset.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
    }
}
