import AppKit
import DiscodromeCore
import SwiftUI

enum TrackColumn: String, CaseIterable {
    case status, number, title, artist, album, time, format, year, genre, plays, size, location

    var header: String {
        switch self {
        case .status: return ""
        case .number: return "#"
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .time: return "Time"
        case .format: return "Format"
        case .year: return "Year"
        case .genre: return "Genre"
        case .plays: return "Plays"
        case .size: return "Size"
        case .location: return "Location"
        }
    }

    var widths: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        switch self {
        case .status: return (22, 22, 22)
        case .number: return (26, 34, 56)
        case .title: return (120, 280, 2000)
        case .artist: return (80, 180, 800)
        case .album: return (80, 200, 800)
        case .time: return (44, 52, 90)
        case .format: return (88, 104, 180)
        case .year: return (40, 48, 80)
        case .genre: return (60, 110, 300)
        case .plays: return (40, 48, 80)
        case .size: return (56, 72, 110)
        case .location: return (120, 320, 2000)
        }
    }

    var isNumeric: Bool {
        switch self {
        case .number, .time, .year, .plays, .size: return true
        default: return false
        }
    }

    var isSecondary: Bool {
        switch self {
        case .number, .time, .format, .year, .genre, .plays, .size, .location: return true
        default: return false
        }
    }

    func text(for track: Track) -> String {
        switch self {
        case .status: return ""
        case .number: return track.trackNumber.map(String.init) ?? ""
        case .title: return track.title
        case .artist: return track.artist
        case .album: return track.album
        case .time: return Formatting.duration(track.duration)
        case .format: return track.formatLabel
        case .year: return track.year.map(String.init) ?? ""
        case .genre: return track.genre ?? ""
        case .plays: return track.playCount.map { $0 > 0 ? String($0) : "" } ?? ""
        case .size: return track.size.map(Formatting.bytes) ?? ""
        case .location: return track.path ?? ""
        }
    }

    /// A key that sorts with plain `<`: localized comparison of 30,000 rows is too slow for a
    /// click on a column header.
    func sortKey(for track: Track) -> String {
        func number(_ value: Int?, width: Int = 4) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let position = number(track.discNumber) + number(track.trackNumber)
        switch self {
        case .status, .number: return position
        case .title: return track.title.librarySortKey.matchKey
        case .artist: return track.artist.librarySortKey.matchKey + "\u{1}" + track.album.librarySortKey.matchKey + "\u{1}" + position
        case .album: return track.album.librarySortKey.matchKey + "\u{1}" + position
        case .time: return number(Int(track.duration), width: 6)
        case .format: return track.formatLabel
        case .year: return number(track.year) + track.album.librarySortKey.matchKey
        case .genre: return (track.genre ?? "").matchKey
        case .plays: return number(track.playCount, width: 7)
        case .size: return number(Int(track.size ?? 0), width: 13)
        case .location: return (track.path ?? "").lowercased()
        }
    }
}

/// The song list: an NSTableView, because the library can hold tens of thousands of rows and
/// needs native type-select, column sorting and resizing, multi-row drag and context menus.
struct TrackTable: NSViewRepresentable {
    struct Style {
        var visibleColumns: [TrackColumn]
        var autosaveName: String
        var sortable = true
        /// Songs on this device's card: enables Delete and Show in Finder.
        var device: Device?
        /// Order used until someone clicks a column header.
        var defaultSort: TrackColumn?
    }

    var tracks: [Track]
    /// Changes whenever `tracks` does, so updates can skip comparing arrays.
    var version: Int
    var style: Style

    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(DeviceManager.self) private var devices

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackNSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.gridStyleMask = []

        for column in TrackColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.header
            tableColumn.minWidth = column.widths.min
            tableColumn.maxWidth = column.widths.max
            tableColumn.width = column.widths.ideal
            tableColumn.headerCell.alignment = column.isNumeric ? .right : .left
            tableColumn.isHidden = !style.visibleColumns.contains(column)
            if column == .status {
                tableColumn.resizingMask = []
                tableColumn.headerToolTip = "Now playing, and whether the song is on your device"
            } else {
                tableColumn.resizingMask = .userResizingMask
                if style.sortable {
                    tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
                }
            }
            table.addTableColumn(tableColumn)
        }
        // Put columns in the order the style lists them.
        for (target, column) in style.visibleColumns.enumerated() {
            let current = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
            if current >= 0, current != target { table.moveColumn(current, toColumn: target) }
        }
        table.autosaveName = style.autosaveName
        table.autosaveTableColumns = true
        if table.sortDescriptors.isEmpty, let column = style.defaultSort {
            table.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: true)]
        }

        let coordinator = context.coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onReturn = { [weak coordinator] in coordinator?.playSelection() }
        table.onDelete = { [weak coordinator] in coordinator?.deleteSelection() ?? false }

        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        table.headerView?.menu = headerMenu

        let scrollView = TrackScrollView()
        scrollView.onTile = { [weak coordinator] width in coordinator?.fitColumns(to: width) }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let presence: [String: DevicePresence]
        let presenceRevision: Int
        let deviceName: String?
        if style.device == nil, let device = devices.primaryDevice, let contents = devices.contents[device.id] {
            presence = contents.match.presence
            presenceRevision = contents.matchRevision
            deviceName = device.name
        } else {
            presence = [:]
            presenceRevision = -1
            deviceName = nil
        }
        context.coordinator.update(
            parent: self,
            nowPlayingID: player.currentTrack?.id,
            presence: presence,
            presenceRevision: presenceRevision,
            deviceName: deviceName,
            revealID: model.revealTrackID
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: TrackTable?
        weak var table: TrackNSTableView?
        private(set) var rows: [Track] = []
        private var sourceVersion = Int.min
        private var sortColumn: TrackColumn?
        private var ascending = true
        private var nowPlayingID: String?
        private var presence: [String: DevicePresence] = [:]
        private var presenceRevision = Int.min
        private var deviceName: String?
        private var suppressSelectionEvents = false
        private var isFittingColumns = false

        /// Columns start at comfortable widths. There's no horizontal scroller, so whenever the
        /// visible columns add up to more than the view is wide, the resizable ones are scaled
        /// down to fit. (`sizeToFit` can't do this: it measures the table, which is already as
        /// wide as its columns.)
        func fitColumns(to width: CGFloat) {
            guard width > 0, !isFittingColumns, let table else { return }
            let visible = table.tableColumns.filter { !$0.isHidden }
            let resizable = visible.filter { $0.resizingMask.contains(.userResizingMask) }
            let fixed = visible.filter { !$0.resizingMask.contains(.userResizingMask) }.reduce(CGFloat(0)) { $0 + $1.width }
            let available = width - fixed - table.intercellSpacing.width * CGFloat(visible.count) - 4
            let current = resizable.reduce(CGFloat(0)) { $0 + $1.width }
            guard current > available, available > 0 else { return }
            isFittingColumns = true
            defer { isFittingColumns = false }
            let scale = available / current
            for column in resizable {
                column.width = max(column.minWidth, (column.width * scale).rounded(.down))
            }
        }

        func update(parent: TrackTable, nowPlayingID: String?, presence: [String: DevicePresence], presenceRevision: Int, deviceName: String?, revealID: String?) {
            self.parent = parent
            guard let table else { return }
            if sortColumn == nil, let descriptor = table.sortDescriptors.first, let column = descriptor.key.flatMap(TrackColumn.init(rawValue:)) {
                sortColumn = column
                ascending = descriptor.ascending
            }

            var statusChanged = false
            if presenceRevision != self.presenceRevision || deviceName != self.deviceName {
                self.presence = presence
                self.presenceRevision = presenceRevision
                self.deviceName = deviceName
                statusChanged = true
            }
            if nowPlayingID != self.nowPlayingID {
                self.nowPlayingID = nowPlayingID
                statusChanged = true
            }

            if parent.version != sourceVersion {
                sourceVersion = parent.version
                let selectedIDs = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
                rows = sorted(parent.tracks)
                suppressSelectionEvents = true
                table.reloadData()
                let indexes = IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].id) })
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                suppressSelectionEvents = false
            } else if statusChanged {
                let status = table.column(withIdentifier: NSUserInterfaceItemIdentifier(TrackColumn.status.rawValue))
                let visible = table.rows(in: table.visibleRect)
                if status >= 0, visible.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: [status])
                }
            }

            if let revealID, let row = rows.firstIndex(where: { $0.id == revealID }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
                table.window?.makeFirstResponder(table)
                Task { @MainActor in parent.model.revealTrackID = nil }
            }
        }

        private func sorted(_ tracks: [Track]) -> [Track] {
            guard let sortColumn else { return tracks }
            let keyed = tracks.map { (sortColumn.sortKey(for: $0), $0) }
            let ordered = keyed.sorted { ascending ? $0.0 < $1.0 : $0.0 > $1.0 }
            return ordered.map(\.1)
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let column = descriptor.key.flatMap(TrackColumn.init(rawValue:)) else { return }
            sortColumn = column
            ascending = descriptor.ascending
            let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            rows = sorted(parent?.tracks ?? rows)
            suppressSelectionEvents = true
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].id) }), byExtendingSelection: false)
            suppressSelectionEvents = false
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard rows.indices.contains(row) else { return nil }
            let track = rows[row]
            let item = NSPasteboardItem()
            if track.isServerTrack, let data = try? JSONEncoder().encode(LibraryDragItem(kind: .track, id: track.id)) {
                item.setData(data, forType: .discodromeItem)
            }
            if let url = track.fileURL {
                item.setString(url.absoluteString, forType: .fileURL)
            }
            item.setString("\(track.title) — \(track.artist)", forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard rows.indices.contains(row), tableColumn?.identifier.rawValue == TrackColumn.title.rawValue else { return nil }
            return rows[row].title
        }

        // MARK: Cells

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn, let column = TrackColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let track = rows[row]
            if column == .status { return statusCell(tableView, track) }

            let identifier = NSUserInterfaceItemIdentifier("cell." + column.rawValue)
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? Self.makeTextCell(identifier, column)
            cell.textField?.stringValue = column.text(for: track)
            return cell
        }

        private static func makeTextCell(_ identifier: NSUserInterfaceItemIdentifier, _ column: TrackColumn) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.alignment = column.isNumeric ? .right : .left
            field.font = column.isNumeric ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
            field.textColor = column.isSecondary ? .secondaryLabelColor : .labelColor
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func statusCell(_ tableView: NSTableView, _ track: Track) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("cell.status")
            let imageView = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSImageView) ?? {
                let view = NSImageView()
                view.identifier = identifier
                view.imageScaling = .scaleNone
                return view
            }()
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            if track.id == nowPlayingID {
                imageView.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Now playing")?.withSymbolConfiguration(configuration)
                imageView.contentTintColor = .controlAccentColor
                imageView.toolTip = "Now playing"
            } else if let place = presence[track.id], let deviceName {
                let exact = place.isExact
                imageView.image = NSImage(systemSymbolName: exact ? "checkmark.circle.fill" : "checkmark.circle", accessibilityDescription: "On \(deviceName)")?.withSymbolConfiguration(configuration)
                imageView.contentTintColor = exact ? .secondaryLabelColor : .tertiaryLabelColor
                imageView.toolTip = exact ? "On \(deviceName)" : "Probably on \(deviceName) — a song with the same tags is there"
            } else {
                imageView.image = nil
                imageView.toolTip = nil
            }
            return imageView
        }

        // MARK: Selection & actions

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionEvents, let table, let parent else { return }
            parent.model.selectedTracks = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            parent?.model.play(rows, startingAt: row)
        }

        func playSelection() {
            guard let table, let first = table.selectedRowIndexes.first else { return }
            if table.selectedRowIndexes.count == 1 {
                parent?.model.play(rows, startingAt: first)
            } else {
                parent?.model.play(table.selectedRowIndexes.map { rows[$0] })
            }
        }

        func deleteSelection() -> Bool {
            guard let table, let parent, let device = parent.style.device else { return false }
            let targets = table.selectedRowIndexes.map { rows[$0] }
            parent.model.requestDeletion(targets, from: device)
            return true
        }

        private func targetRows(_ table: NSTableView) -> [Track] {
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                return rows.indices.contains(clicked) ? [rows[clicked]] : []
            }
            return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let parent else { return }

            if menu === table.headerView?.menu {
                for column in TrackColumn.allCases where column != .status && column != .title {
                    guard let tableColumn = table.tableColumns.first(where: { $0.identifier.rawValue == column.rawValue }) else { continue }
                    let item = ActionMenuItem(column.header) { [weak self, weak table] in
                        tableColumn.isHidden.toggle()
                        if let width = table?.enclosingScrollView?.contentView.bounds.width { self?.fitColumns(to: width) }
                    }
                    item.state = tableColumn.isHidden ? .off : .on
                    menu.addItem(item)
                }
                return
            }

            let targets = targetRows(table)
            guard !targets.isEmpty else { return }
            let model = parent.model
            let player = model.player
            let rows = self.rows

            menu.addItem(ActionMenuItem("Play", symbol: "play") {
                if targets.count == 1, let index = rows.firstIndex(of: targets[0]) {
                    model.play(rows, startingAt: index)
                } else {
                    model.play(targets)
                }
            })
            menu.addItem(ActionMenuItem("Play Next", symbol: "text.line.first.and.arrowtriangle.forward") { player.playNext(targets) })
            menu.addItem(ActionMenuItem("Add to Up Next", symbol: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(targets) })

            let serverTracks = targets.filter(\.isServerTrack)
            if parent.style.device == nil, !serverTracks.isEmpty, let device = model.devices.primaryDevice {
                menu.addItem(.separator())
                let title = serverTracks.count == 1 ? "Copy to “\(device.name)”" : "Copy \(serverTracks.count) Songs to “\(device.name)”"
                menu.addItem(ActionMenuItem(title, symbol: "arrow.down.to.line") { model.copy(serverTracks, to: device) })
            }

            if let device = parent.style.device {
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Show in Finder", symbol: "folder") { model.revealInFinder(targets) })
                let title = targets.count == 1 ? "Delete from “\(device.name)”…" : "Delete \(targets.count) Songs from “\(device.name)”…"
                menu.addItem(ActionMenuItem(title, symbol: "trash") { model.requestDeletion(targets, from: device) })
            }

            if targets.count == 1, targets[0].isServerTrack, targets[0].albumID != nil {
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Go to Album", symbol: "square.stack") { model.goToAlbum(of: targets[0]) })
            }
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Get Info", symbol: "info.circle") {
                model.selectedTracks = targets
                model.showInfo()
            })
        }
    }
}

final class TrackScrollView: NSScrollView {
    var onTile: ((CGFloat) -> Void)?

    override func tile() {
        super.tile()
        onTile?(contentView.bounds.width)
    }
}

final class TrackNSTableView: NSTableView {
    var onReturn: (() -> Void)?
    /// Returns whether the key was handled.
    var onDelete: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onReturn?()
        case 51, 117:
            if onDelete?() != true { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }
}

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
