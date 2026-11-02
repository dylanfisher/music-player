import AppKit
import Commands
import DisplayText
import KeyChord
import Library
import Settings

/// The source list: the library, History, the timeline and the health checks, and the playlists.
/// Tracks dragged from the table onto a manual playlist are added to it; playlist files dropped
/// anywhere on it are imported. The watched folders are in Settings.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = KeyOutlineView()
    private let library = SidebarNode(.library, title: "Music")
    /// Opens into one row per health check; not a source itself.
    private let health = SidebarNode(.health, title: "Library Health")
    private let groups: [SidebarNode]
    private let playlistGroup = SidebarNode(.group, title: "Playlists")
    private let selectSource: (BrowserSource?) -> Void
    /// Tracks, by ID, dropped on the manual playlist with this ID.
    var dropTracks: (Int64, [Int64]) -> Void = { _, _ in }
    /// Playlist files, by URL, dropped on the sidebar.
    var dropPlaylistFiles: ([URL]) -> Void = { _ in }
    private let keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
    private var applying = false
    private var typeSelect: TypeSelect?
    private var playlists: [Playlist] = []

    init(
        selectSource: @escaping (BrowserSource?) -> Void,
        keyCommand: @escaping ([KeyChord]) -> CommandDispatcher.KeyOutcome
    ) {
        self.selectSource = selectSource
        self.keyCommand = keyCommand
        let libraryGroup = SidebarNode(.group, title: "Library")
        libraryGroup.children = [
            library, SidebarNode(.history, title: "History"),
            SidebarNode(.timeline, title: "Timeline"), health,
        ]
        health.children = HealthCheck.allCases.map { check in
            let node = SidebarNode(.check(check), title: check.title)
            node.toolTip = check.summary
            return node
        }
        groups = [libraryGroup, playlistGroup]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.takeKey = { [weak self] event in self?.takeKey(event) ?? false }
        outline.registerForDraggedTypes([trackIDsType, .fileURL])
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // The window's sidebar split item draws the material behind it.
        view = scroll
        outline.reloadData()
        for group in groups { outline.expandItem(group) }
    }

    /// Lists `playlists` and selects `source`, the library for nil.
    func show(playlists: [Playlist], source: BrowserSource?) {
        self.playlists = playlists
        applying = true
        defer { applying = false }
        let open = openRows()
        playlistGroup.children = playlists.map { playlist in
            let node = SidebarNode(.playlist(playlist), title: playlist.name)
            if case .unreadable(let reason) = playlist.kind { node.toolTip = reason }
            return node
        }
        outline.reloadData()
        for group in groups { outline.expandItem(group) }
        for node in open { outline.expandItem(node) }
        let selected = source.flatMap(row(for:)) ?? outline.row(forItem: library)
        outline.selectRowIndexes([selected], byExtendingSelection: false)
        outline.scrollRowToVisible(selected)
    }

    /// Selects `source` without reporting it, for Back and Forward.
    func show(source: BrowserSource?) {
        show(playlists: playlists, source: source)
    }

    /// Shows what each health check found, as a count after its name.
    func show(health report: HealthReport) {
        for node in health.children {
            guard case .check(let check) = node.kind else { continue }
            node.count = number(report[check].count)
        }
        // Only the rows' text, so the selection stays; closed rows read it when they open.
        let rows = health.children.map { outline.row(forItem: $0) }.filter { $0 >= 0 }
        outline.reloadData(forRowIndexes: IndexSet(rows), columnIndexes: [0])
    }

    /// Opens the health checks' rows.
    func openHealth() { outline.expandItem(health) }

    /// The row showing `source`, opening the rows above it; nil when there's none.
    private func row(for source: BrowserSource) -> Int? {
        var node = groups.lazy.flatMap(\.children).first { $0.source == source }
        if case .health = source {
            outline.expandItem(health)
            node = health.children.first { $0.source == source }
        }
        guard let node else { return nil }
        let row = outline.row(forItem: node)
        return row >= 0 ? row : nil
    }

    /// The open rows below the group headings, which outlive a reload, in row order.
    private func openRows() -> [SidebarNode] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SidebarNode, node.kind != .group,
                outline.isItemExpanded(node)
            else { return nil }
            return node
        }
    }

    /// The outline moves through its own rows, skipping the group headings; every other key
    /// goes through the registry.
    private func takeKey(_ event: NSEvent) -> Bool {
        let own: [KeyChord.Key] = [.up, .down, .home, .end, .pageUp, .pageDown]
        if let chord = KeyChord(event: event), own.contains(chord.key),
            chord.modifiers.isSubset(of: .shift)
        {
            return false
        }
        return routeKey(event, typeSelect: &typeSelect, keyCommand: keyCommand) { _ in }
    }

    private var selectedNode: SidebarNode? {
        outline.item(atRow: outline.selectedRow) as? SidebarNode
    }

    /// What the selected row shows; nil for the library.
    var selectedSource: BrowserSource? { selectedNode?.source }

    // MARK: Data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode).map { $0.children.count } ?? groups.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode).map { $0.children[index] } ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        switch node.kind {
        case .group, .health: return true
        case .library, .history, .timeline, .playlist, .check: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .group
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if node.kind == .health {
            // A click opens or closes it, as its triangle does; the keys pass over it.
            if NSApp.currentEvent?.type == .leftMouseDown {
                if outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node)
                } else {
                    outlineView.expandItem(node)
                }
            }
            return false
        }
        return node.kind != .group
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        guard let node = item as? SidebarNode else { return nil }
        let isGroup = node.kind == .group
        let identifier = NSUserInterfaceItemIdentifier(isGroup ? "HeaderCell" : "DataCell")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCell(identifier)
        cell.textField?.stringValue = isGroup ? node.title.uppercased() : node.title
        cell.textField?.font =
            isGroup
            ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            : .systemFont(ofSize: NSFont.systemFontSize)
        cell.textField?.textColor = isGroup ? .secondaryLabelColor : .labelColor
        cell.imageView?.image = node.symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        // A row without a symbol gives its width to the name.
        (cell as? CountCell)?.imageWidth?.constant = node.symbol == nil ? 0 : 16
        cell.toolTip = node.toolTip
        (cell as? CountCell)?.count.stringValue = node.count ?? ""
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let isData = identifier.rawValue == "DataCell"
        let cell = isData ? CountCell() : NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if identifier.rawValue == "DataCell" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            let width = image.widthAnchor.constraint(equalToConstant: 16)
            width.isActive = true
            (cell as? CountCell)?.imageWidth = width
            leading = image.trailingAnchor
        }
        var trailing = cell.trailingAnchor
        if let cell = cell as? CountCell {
            // The count keeps its width; the name is cut short first.
            let count = cell.count
            count.textColor = .secondaryLabelColor
            count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            count.alignment = .right
            count.translatesAutoresizingMaskIntoConstraints = false
            count.setContentCompressionResistancePriority(.required, for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(count)
            NSLayoutConstraint.activate([
                count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                count.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            trailing = count.leadingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 4),
            text.trailingAnchor.constraint(equalTo: trailing, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Dropping tracks on a playlist

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if !playlistFileURLs(info.draggingPasteboard).isEmpty {
            // A file goes to the playlists, not to the row it's over.
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        guard index == NSOutlineViewDropOnItemIndex,
            case .playlist(let playlist) = (item as? SidebarNode)?.kind,
            playlist.isManual
        else { return [] }
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?,
        childIndex index: Int
    ) -> Bool {
        let files = playlistFileURLs(info.draggingPasteboard)
        if !files.isEmpty {
            dropPlaylistFiles(files)
            return true
        }
        guard case .playlist(let playlist) = (item as? SidebarNode)?.kind, playlist.isManual
        else { return false }
        let ids = draggedTrackIDs(info.draggingPasteboard)
        guard !ids.isEmpty else { return false }
        dropTracks(playlist.id, ids)
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        switch selectedNode?.kind {
        case .library: selectSource(nil)
        case .group, .health, nil: break
        case .history, .timeline, .playlist, .check: selectSource(selectedNode?.source)
        }
    }
}

/// The files on `pasteboard` with a playlist file's extension, in order. Others are left out,
/// so a drag of only those isn't taken.
func playlistFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
    let urls =
        pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.filter { PlaylistFile.Format(fileExtension: $0.pathExtension) != nil }
}

/// A row of the source list. A class, since NSOutlineView tells items apart by identity.
private final class SidebarNode {
    enum Kind: Equatable {
        case group, library, history, timeline, health
        case playlist(Playlist)
        case check(HealthCheck)
    }

    let kind: Kind
    let title: String
    var toolTip: String?
    /// A health check's count, shown at the row's end.
    var count: String?
    var children: [SidebarNode] = []

    /// What selecting the row shows; nil for the library and the group headings.
    var source: BrowserSource? {
        switch kind {
        case .playlist(let playlist): .playlist(playlist.id)
        case .history: .history
        case .timeline: .timeline
        case .check(let check): .health(check)
        case .group, .library, .health: nil
        }
    }

    /// The row's SF Symbol.
    var symbol: String? {
        switch kind {
        case .group: nil
        case .library: "music.note"
        case .history: "clock"
        case .timeline: "list.bullet"
        case .health: "stethoscope"
        // The checks' names need the room for their counts.
        case .check: nil
        case .playlist(let playlist):
            switch playlist.kind {
            case .manual: SymbolName.playlist
            case .smart: "gearshape"
            case .unreadable: "exclamationmark.triangle"
            }
        }
    }

    init(_ kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}

/// A row with a count at its end, empty for rows that have none.
private final class CountCell: NSTableCellView {
    let count = NSTextField(labelWithString: "")
    var imageWidth: NSLayoutConstraint?
}
