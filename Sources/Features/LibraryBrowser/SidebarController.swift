import AppKit
import Commands
import DisplayText
import KeyChord
import Library
import Settings

/// The source list: the library and History, the playlists and the watched folders, with
/// buttons to add and remove folders. Tracks dragged from the table onto a manual playlist are
/// added to it.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = KeyOutlineView()
    private let library = SidebarNode(.library, title: "Music")
    private let groups: [SidebarNode]
    private let playlistGroup = SidebarNode(.group, title: "Playlists")
    private let folderGroup = SidebarNode(.group, title: "Watched Folders")
    private let selectSource: (BrowserSource?) -> Void
    /// Tracks, by ID, dropped on the manual playlist with this ID.
    var dropTracks: (Int64, [Int64]) -> Void = { _, _ in }
    private let addFolder: () -> Void
    private let removeFolder: (String) -> Void
    private let keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
    private let removeButton = NSButton()
    private var applying = false
    private var typeSelect: TypeSelect?
    private var folders: [WatchedFolder] = []
    private var playlists: [Playlist] = []

    init(
        selectSource: @escaping (BrowserSource?) -> Void, addFolder: @escaping () -> Void,
        removeFolder: @escaping (String) -> Void,
        keyCommand: @escaping ([KeyChord]) -> CommandDispatcher.KeyOutcome
    ) {
        self.selectSource = selectSource
        self.addFolder = addFolder
        self.removeFolder = removeFolder
        self.keyCommand = keyCommand
        let libraryGroup = SidebarNode(.group, title: "Library")
        libraryGroup.children = [library, SidebarNode(.history, title: "History")]
        groups = [libraryGroup, playlistGroup, folderGroup]
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
        outline.registerForDraggedTypes([trackIDsType])
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let add = NSButton(
            title: "+", target: self, action: #selector(addClicked))
        add.toolTip = "Add a watched folder"
        removeButton.title = "−"
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.toolTip = "Stop watching the selected folder"
        for button in [add, removeButton] {
            button.bezelStyle = .smallSquare
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let buttons = NSStackView(views: [add, removeButton])
        buttons.spacing = 0
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        view = effect
        outline.reloadData()
        for group in groups { outline.expandItem(group) }
    }

    /// Lists `folders` and `playlists` and selects `source`, the library for nil.
    func show(folders: [WatchedFolder], playlists: [Playlist], source: BrowserSource?) {
        self.folders = folders
        self.playlists = playlists
        applying = true
        defer { applying = false }
        playlistGroup.children = playlists.map { playlist in
            let node = SidebarNode(.playlist(playlist), title: playlist.name)
            if case .unreadable(let reason) = playlist.kind { node.toolTip = reason }
            return node
        }
        folderGroup.children = folders.map { folder in
            let node = SidebarNode(.folder(folder.path), title: displayName(folder.path))
            node.toolTip =
                folder.path + (folder.kind == .network ? " (network, polled)" : " (local)")
            return node
        }
        outline.reloadData()
        for group in groups { outline.expandItem(group) }
        let selected =
            source.flatMap { source in
                groups.lazy.flatMap(\.children).first { $0.source == source }
            } ?? library
        outline.selectRowIndexes([outline.row(forItem: selected)], byExtendingSelection: false)
        updateRemoveButton()
    }

    /// Selects `source` without reporting it, for Back and Forward.
    func show(source: BrowserSource?) {
        show(folders: folders, playlists: playlists, source: source)
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

    private func updateRemoveButton() {
        if case .folder = selectedNode?.kind {
            removeButton.isEnabled = true
        } else {
            removeButton.isEnabled = false
        }
    }

    @objc private func addClicked() { addFolder() }

    @objc private func removeClicked() {
        guard case .folder(let path) = selectedNode?.kind else { return }
        removeFolder(path)
    }

    // MARK: Data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? groups.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .group
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .group
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .group
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
        cell.toolTip = node.toolTip
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
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
                image.widthAnchor.constraint(equalToConstant: 16),
            ])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
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
        guard case .playlist(let playlist) = (item as? SidebarNode)?.kind, playlist.isManual
        else { return false }
        let ids = draggedTrackIDs(info.draggingPasteboard)
        guard !ids.isEmpty else { return false }
        dropTracks(playlist.id, ids)
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
        guard !applying else { return }
        switch selectedNode?.kind {
        case .library: selectSource(nil)
        case .group, nil: break
        case .folder, .history, .playlist: selectSource(selectedNode?.source)
        }
    }
}

/// A row of the source list. A class, since NSOutlineView tells items apart by identity.
private final class SidebarNode {
    enum Kind: Equatable {
        case group, library, history
        case folder(String)
        case playlist(Playlist)
    }

    let kind: Kind
    let title: String
    var toolTip: String?
    var children: [SidebarNode] = []

    /// What selecting the row shows; nil for the library and the group headings.
    var source: BrowserSource? {
        switch kind {
        case .folder(let path): .folder(path)
        case .playlist(let playlist): .playlist(playlist.id)
        case .history: .history
        case .group, .library: nil
        }
    }

    /// The row's SF Symbol.
    var symbol: String? {
        switch kind {
        case .group: nil
        case .library: "music.note"
        case .history: "clock"
        case .folder: "folder"
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

/// A folder's name as the sidebar shows it: its last component, or the path for "/".
private func displayName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty || name == "/" ? path : name
}
