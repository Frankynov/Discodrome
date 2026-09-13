import AppKit
import DiscodromeCore
import SwiftUI

/// Development aid. With DISCODROME_SNAPSHOTS=/some/folder the app walks through its main
/// screens once the library has loaded, exercises playback and the device, logs what it sees
/// to standard error and saves a picture of the window at each step. Does nothing otherwise.
@MainActor
enum DevSnapshots {
    static func runIfRequested(_ model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["DISCODROME_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        Task {
            // Not before launch has finished: NSApp doesn't exist while the model is being made.
            if environment["DISCODROME_APPEARANCE"] == "light" {
                NSApp.appearance = NSAppearance(named: .aqua)
            }
            await walkthrough(model, directory: directory)
            if environment["DISCODROME_SNAPSHOTS_QUIT"] != nil {
                model.player.stop()
                try? await Task.sleep(for: .seconds(0.5))
                NSApp.terminate(nil)
            }
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await pause(0.1) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("snapshots: \(message)\n".utf8))
    }

    private static func walkthrough(_ model: AppModel, directory: URL) async {
        let player = model.player
        let devices = model.devices
        let transfers = model.transfers

        await waitUntil(60) { !model.library.albums.isEmpty && !model.library.isSyncing }
        log("library: \(model.library.albums.count) albums, \(model.library.tracks.count) songs")
        if ProcessInfo.processInfo.environment["DISCODROME_SNAPSHOTS_ONLY"] == "stream" {
            await streamCheck(model, directory: directory)
            return
        }
        if ProcessInfo.processInfo.environment["DISCODROME_SNAPSHOTS_ONLY"] == "inspector" {
            await inspectorCheck(model, directory: directory)
            return
        }
        if ProcessInfo.processInfo.environment["DISCODROME_SNAPSHOTS_ONLY"] == "review" {
            await review(model, directory: directory)
            return
        }
        if ProcessInfo.processInfo.environment["DISCODROME_SNAPSHOTS_ONLY"] == "layout" {
            if let album = model.library.albums.first(where: { $0.name == "Northbound" }) ?? model.library.albums.first {
                model.play(album)
                await pause(3)
                save("layout-1-albums", to: directory)
                model.navigationPath = NavigationPath([album])
                await pause(2)
                save("layout-2-album", to: directory)
            }
            if let device = devices.primaryDevice {
                model.navigationPath = NavigationPath()
                model.sidebarSelection = .device(device.id)
                await pause(2.5)
                save("layout-3-device", to: directory)
            }
            return
        }
        if ProcessInfo.processInfo.environment["DISCODROME_SNAPSHOTS_ONLY"] == "chrome" {
            if let album = model.library.albums.first { model.play(album) }
            await pause(3)
            await captureChrome(model, directory: directory)
            return
        }
        await pause(2.5)
        save("01-albums", to: directory)

        guard let album = model.library.albums.first(where: { $0.name == "Northbound" }) ?? model.library.albums.first else { return }
        model.navigationPath = NavigationPath([album])
        await pause(2)
        save("02-album", to: directory)

        model.play(album)
        model.inspectorTab = .lyrics
        await pause(7)
        log("player: \(player.state.status) at \(String(format: "%.2f", player.state.position())) s in \(player.currentTrack?.title ?? "-")")
        save("03-playing-lyrics", to: directory)

        // A track change: jump near the end of the song and watch the next one take over.
        let firstIndex = player.state.currentIndex
        player.seek(to: max(0, player.state.duration - 2.5))
        let start = Date()
        var switchedAfter: Double?
        var interruptions = 0
        var lastStatus = player.state.status
        while Date().timeIntervalSince(start) < 5 {
            await pause(0.05)
            let elapsed = Date().timeIntervalSince(start)
            if player.state.status != lastStatus {
                lastStatus = player.state.status
                if elapsed > 0.3, lastStatus != .playing { interruptions += 1 }
            }
            if switchedAfter == nil, player.state.currentIndex != firstIndex { switchedAfter = elapsed }
        }
        log("track change: \(switchedAfter.map { String(format: "moved to \"%@\" after %.2f s", player.currentTrack?.title ?? "?", $0) } ?? "didn't happen"), \(interruptions == 0 ? "playing throughout" : "\(interruptions) interruption(s)")")

        model.inspectorTab = .upNext
        model.sidebarSelection = .songs
        await pause(2)
        save("04-songs-upnext", to: directory)

        guard let device = devices.primaryDevice else { return }
        model.sidebarSelection = .device(device.id)
        model.inspectorTab = .info
        await waitUntil(10) { devices.contents[device.id]?.hasScanned == true }
        await pause(2)
        if let contents = devices.contents[device.id] {
            log("device: \(contents.files.count) files, \(contents.match.presence.count) library songs present, \(contents.clutter.count) macOS files")
        }
        save("05-device", to: directory)
        log("clean-up removed \(devices.cleanUp(device)) macOS file(s)")

        model.sidebarSelection = .albums
        await pause(0.8)
        model.navigationPath = NavigationPath([album])
        await pause(1.5)
        model.copy(album, to: device)
        await waitUntil(5) { transfers.activeJob != nil }
        await pause(1.2)
        save("06-copying", to: directory)
        await waitUntil(90) { !transfers.isActive }
        await pause(1.5)
        log("copy: \(transfers.summary ?? "no summary")")
        save("07-copied", to: directory)

        // Delete a song from the card, copy it back, and check its lyrics came along.
        if let tide = model.library.tracks.first(where: { $0.title == "Tide" }),
           let place = devices.presence(of: tide.id, on: device.id) {
            devices.delete([place.relativePath], from: device)
            await pause(1.5)
            log("delete \(place.relativePath): \(devices.presence(of: tide.id, on: device.id) == nil ? "gone from the card" : "still matched")")
            model.copy([tide], to: device)
            await waitUntil(5) { transfers.isActive }
            await waitUntil(60) { !transfers.isActive }
            await pause(1)
            if let copied = devices.presence(of: tide.id, on: device.id) {
                let lyrics = device.url.appending(path: copied.relativePath).deletingPathExtension().appendingPathExtension("lrc")
                log("copied back to \(copied.relativePath) (\(copied.isExact ? "exact" : "likely")); lyrics file \(FileManager.default.fileExists(atPath: lyrics.path) ? "written" : "missing")")
            } else {
                log("copy back failed: \(transfers.summary ?? "?")")
            }
        }
        model.sidebarSelection = .device(device.id)
        await pause(2.5)
        save("08-device-after", to: directory)

        await captureChrome(model, directory: directory)
    }

    /// The toolbar in Icon and Text mode, where every button needs its caption, and Settings.
    private static func captureChrome(_ model: AppModel, directory: URL) async {
        if let window = mainWindow, let toolbar = window.toolbar {
            let labels = toolbar.items.map { $0.label.isEmpty ? "[\($0.itemIdentifier.rawValue)]" : $0.label }
            log("toolbar items: \(labels.joined(separator: " | "))")
            log("toolbar: user-customizable \(toolbar.allowsUserCustomization), display mode \(toolbar.displayMode.rawValue)")
            let previous = toolbar.displayMode
            toolbar.displayMode = .iconAndLabel
            await pause(1.5)
            log("toolbar display mode now \(toolbar.displayMode.rawValue), \(toolbar.visibleItems?.count ?? -1) items visible")
            save("09-toolbar-icon-and-text", to: directory)
            toolbar.displayMode = previous
        }

        model.openSettingsWindow?()
        await pause(2)
        let main = mainWindow
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.contentView != nil && $0.frame.width > 200 }) {
            log("settings window: \(settings.identifier?.rawValue ?? "no identifier"), \(Int(settings.frame.width))×\(Int(settings.frame.height))")
            save("10-settings", window: settings, to: directory)
            settings.close()
        } else {
            log("settings window not found among: \(NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") visible=\($0.isVisible)" })")
        }
    }

    /// The artists page, two copies to the device (for the Transfers tab), and content scrolled
    /// under the toolbar in a shorter window.
    private static func review(_ model: AppModel, directory: URL) async {
        let devices = model.devices
        let transfers = model.transfers
        guard let northbound = model.library.albums.first(where: { $0.name == "Northbound" }),
              let afterglow = model.library.albums.first(where: { $0.name == "Afterglow" }) else { return }
        model.play(northbound)
        model.navigationPath = NavigationPath([northbound])
        await pause(2.5)
        save("review-0-album", to: directory)
        model.navigationPath = NavigationPath()
        model.sidebarSelection = .artists
        await pause(3)
        save("review-1-artists", to: directory)

        guard let device = devices.primaryDevice else { return }
        await waitUntil(10) { devices.contents[device.id]?.hasScanned == true }
        for album in [northbound, afterglow] {
            model.copy(album, to: device)
            await waitUntil(5) { transfers.isActive }
            await waitUntil(90) { !transfers.isActive }
        }
        model.sidebarSelection = .device(device.id)
        model.deviceShowsTransfers = true
        await pause(2.5)
        log("transfers: \(transfers.batches.count) copies, \(transfers.jobs.count) songs; titles: \(transfers.batches.map(\.title))")
        save("review-2-transfers", to: directory)

        model.sidebarSelection = .albums
        guard let window = mainWindow else { return }
        let original = window.frame
        var shorter = original
        shorter.size.height = 640
        shorter.origin.y += original.height - 640
        window.setFrame(shorter, display: true)
        await pause(1.5)
        let scrolled = scrollViews(in: window.contentView).filter { !($0.documentView is NSTableView) }
        for scrollView in scrolled {
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + 170))
            scrollView.reflectScrolledClipView(clip)
        }
        log("scrolled \(scrolled.count) scroll views")
        await pause(1)
        save("review-3-scrolled", to: directory)
        window.setFrame(original, display: true)
    }

    /// Songs that haven't downloaded yet: how soon they start, whether the next song still follows
    /// without a gap, and search results holding a cover that isn't square.
    /// `DISCODROME_STREAM_NATURAL` listens on into the second song instead of seeking to the end.
    private static func streamCheck(_ model: AppModel, directory: URL) async {
        let player = model.player
        guard let album = model.library.albums.first(where: { $0.name == "Northbound" }) else { return }
        let tracks = await model.library.tracks(for: album)
        guard tracks.count > 1 else { return }
        let server = player.provider.serverProvider
        let underrunsBefore = player.state.underruns
        let started = ProcessInfo.processInfo.systemUptime
        let elapsed = { ProcessInfo.processInfo.systemUptime - started }

        model.play(album)
        var playingAfter: Double?
        var downloadedAfter: Double?
        while elapsed() < 60, playingAfter == nil || downloadedAfter == nil {
            if playingAfter == nil, player.state.status == .playing { playingAfter = elapsed() }
            if downloadedAfter == nil, server?.cachedFile(for: tracks[0]) != nil { downloadedAfter = elapsed() }
            await pause(0.05)
        }
        log(String(format: "first song (%@, %@): playing after %.2f s, fully downloaded after %.2f s",
                   tracks[0].title, Formatting.bytes(tracks[0].size ?? 0), playingAfter ?? -1, downloadedAfter ?? -1))

        if ProcessInfo.processInfo.environment["DISCODROME_STREAM_NATURAL"] != nil {
            // Listen on into the second song, which downloads meanwhile.
            while elapsed() < 120, player.state.currentIndex == 0 { await pause(0.02) }
            let stillDownloading = server?.cachedFile(for: tracks[1]) == nil
            log(String(format: "second song began at %.2f s, %@", elapsed(), stillDownloading ? "still downloading" : "already downloaded"))
            await pause(5)
        } else {
            // Straight to the end of the first song.
            await pause(6)
            player.seek(to: max(0, player.state.duration - 2.5))
            let seekStart = elapsed()
            var switchedAfter: Double?
            while elapsed() - seekStart < 6 {
                await pause(0.05)
                if switchedAfter == nil, player.state.currentIndex != 0 { switchedAfter = elapsed() - seekStart }
            }
            log("track change: " + (switchedAfter.map { String(format: "moved to “%@” after %.2f s", player.currentTrack?.title ?? "?", $0) } ?? "didn't happen"))
        }
        log("underruns: \(player.state.underruns - underrunsBefore), now \(player.state.status)")

        model.searchText = "te"
        await pause(3)
        save("stream-search", to: directory)
        model.searchText = ""
    }

    /// The inspector's tabs belong in the toolbar only while it's open: pictures of the window open,
    /// closed and reopened, and the toolbar's trailing controls traced through each animation.
    private static func inspectorCheck(_ model: AppModel, directory: URL) async {
        if let album = model.library.albums.first(where: { $0.name == "Northbound" }) ?? model.library.albums.first {
            model.play(album)
        }
        model.inspectorTab = .lyrics
        await pause(3)
        save("inspector-1-open", to: directory)
        await trace("closing") { model.showInspector = false }
        save("inspector-2-closed", to: directory)
        await trace("opening") { model.showInspector = true }
        save("inspector-3-reopened", to: directory)
        log("tab after reopening: \(model.inspectorTab.rawValue)")
        await trace("closing, then reopening halfway") {
            model.showInspector = false
            await Self.pause(0.12)
            model.showInspector = true
        }
        save("inspector-4-reversed", to: directory)
        log("after the reversal: showInspector \(model.showInspector), column \(Int(inspectorPane()?.frame.width ?? -1)) pt wide")

        // The same, lightly measured: does the main thread miss a refresh when the tabs come and go?
        model.showInspector = false
        await pause(1)
        model.showInspector = true
        await pause(1)
        for round in 1...3 {
            await pacing("closing \(round)") { model.showInspector = false }
            await pacing("opening \(round)") { model.showInspector = true }
        }
    }

    /// Samples `toolbarLayout()` for a second after `change`, keeping each new state with its time —
    /// a jump shows as a leap between neighbouring lines.
    private static func trace(_ label: String, _ change: () async -> Void) async {
        let trace = LayoutTrace()
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            MainActor.assumeIsolated {
                let layout = Self.toolbarLayout()
                guard layout != trace.last else { return }
                trace.last = layout
                trace.lines.append(String(format: "%6.0f ms  ", (ProcessInfo.processInfo.systemUptime - start) * 1000) + layout)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trace.last = toolbarLayout()
        trace.lines.append("  before   " + trace.last)
        await change()
        await pause(1.2)
        timer.invalidate()
        log("\(label):\n" + trace.lines.joined(separator: "\n"))
    }

    /// Column widths, and where the toolbar's tabs, inspector button and volume slider sit, in points
    /// from the window's trailing edge; anything partly transparent shows its opacity.
    private static func toolbarLayout() -> String {
        guard let window = mainWindow, let frameView = window.contentView?.superview else { return "no window" }
        let width = window.frame.width
        func place(_ view: NSView) -> String {
            let frame = view.convert(view.bounds, to: nil)
            var opacity: CGFloat = 1
            var ancestor: NSView? = view
            while let current = ancestor {
                opacity *= current.alphaValue
                ancestor = current.superview
            }
            let range = String(format: "%.0f–%.0f", width - frame.maxX, width - frame.minX)
            return opacity < 0.99 ? range + String(format: " @%.2f", opacity) : range
        }
        let views = descendants(of: frameView).filter { !$0.isHiddenOrHasHiddenAncestor }
        // Each pane's width, and in brackets its content's where that differs.
        let columns = views.compactMap { $0 as? NSSplitView }.map { split in
            split.arrangedSubviews.map { pane in
                let width = pane.isHidden ? 0 : pane.frame.width
                let content = pane.subviews.map { $0.frame.width }.max() ?? width
                return abs(content - width) < 0.5 ? String(format: "%.0f", width) : String(format: "%.0f(%.0f)", width, content)
            }.joined(separator: "|")
        }
        let tabs = views.filter { $0 is NSSegmentedControl }.map(place)
        let toggleItem = window.toolbar?.visibleItems?.first { $0.label == "Inspector" }
        let toggle = (toggleItem?.view ?? views.first { $0.accessibilityLabel() == "Inspector" }).map(place) ?? "?"
        let volume = views.filter { $0 is NSSlider }.map(place)
        return "columns \(columns.joined(separator: " / "))  tabs \(tabs.isEmpty ? "none" : tabs.joined(separator: ", "))"
            + "  inspector button \(toggle)  volume \(volume.joined(separator: ", "))"
    }

    /// Frame pacing while `change` runs, without `trace`'s own cost: the inspector pane's width on every
    /// display refresh, reporting refreshes the main thread missed and when the toolbar's items changed.
    private static func pacing(_ label: String, _ change: () async -> Void) async {
        guard let window = mainWindow, let frameView = window.contentView?.superview, let pane = inspectorPane() else { return }
        let sampler = FrameSampler(pane: pane, toolbar: window.toolbar)
        let link = frameView.displayLink(target: sampler, selector: #selector(FrameSampler.tick(_:)))
        link.add(to: .main, forMode: .common)
        await change()
        await pause(1)
        link.invalidate()
        log("\(label): " + sampler.report())
    }

    private static func inspectorPane() -> NSView? {
        guard let frameView = mainWindow?.contentView?.superview else { return nil }
        return descendants(of: frameView).compactMap { $0 as? NSSplitView }.first?.arrangedSubviews.last
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// Draws a window — the main one unless told otherwise, title bar and toolbar included — into a PNG.
    static func save(_ name: String, window: NSWindow? = nil, to directory: URL) {
        guard let window = window ?? mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        // DISCODROME_REAL_CAPTURE: the pixels on screen, including what only the window server
        // draws (materials, edge effects) — drawing the view hierarchy leaves those out.
        if ProcessInfo.processInfo.environment["DISCODROME_REAL_CAPTURE"] != nil {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", directory.appending(path: "\(name).png").path]
            try? capture.run()
            capture.waitUntilExit()
            return
        }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }
}

/// What `DevSnapshots.trace` has seen so far.
@MainActor
private final class LayoutTrace {
    var lines: [String] = []
    var last = ""
}

/// Samples for `DevSnapshots.pacing`, one per display refresh.
@MainActor
private final class FrameSampler: NSObject {
    private let pane: NSView
    private weak var toolbar: NSToolbar?
    private var samples: [(time: CFTimeInterval, width: CGFloat, items: Int)] = []

    init(pane: NSView, toolbar: NSToolbar?) {
        self.pane = pane
        self.toolbar = toolbar
    }

    @objc func tick(_ link: CADisplayLink) {
        samples.append((link.timestamp, pane.frame.width, toolbar?.visibleItems?.count ?? 0))
    }

    /// The animation, from the refresh before its first change of width to the one after its last:
    /// refreshes the main thread missed, the longest wait between two, and when the toolbar changed.
    func report() -> String {
        guard samples.count > 3 else { return "no samples" }
        let gaps = zip(samples.dropFirst(), samples).map { $0.time - $1.time }.sorted()
        let refresh = gaps[gaps.count / 2]
        guard let first = samples.firstIndex(where: { $0.width != samples[0].width }),
              let last = samples.lastIndex(where: { $0.width != samples[samples.count - 1].width }) else { return "didn't animate" }
        let from = max(1, first), to = min(samples.count - 1, last + 1)
        let start = samples[from - 1].time
        var missed = 0
        var longest: (gap: Double, after: Double) = (0, 0)
        var toolbarChange = ""
        for i in from...to {
            let gap = samples[i].time - samples[i - 1].time
            missed += max(0, Int((gap / refresh).rounded()) - 1)
            if gap > longest.gap { longest = (gap, samples[i - 1].time - start) }
            if samples[i].items != samples[i - 1].items {
                toolbarChange = String(format: ", toolbar changed at %.0f ms", (samples[i].time - start) * 1000)
            }
        }
        return String(format: "%3.0f ms, %2d of %2d refreshes missed, longest gap %2.0f ms after %3.0f ms",
                      (samples[to].time - start) * 1000, missed, to - from + 1 + missed, longest.gap * 1000, longest.after * 1000)
            + toolbarChange
    }
}
