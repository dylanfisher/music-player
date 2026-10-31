import AppKit
import Commands
import KeyChord
import Settings

/// The source list: the library, playlists (none until there are any) and the watched folders,
/// with buttons to add and remove folders.
@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = KeyOutlineView()
    private let library = SidebarNode(.library, title: "Music")
    private let groups: [SidebarNode]
    private let folderGroup = SidebarNode(.group, title: "Watched Folders")
    private let selectSource: (String?) -> Void
    private let addFolder: () -> Void
    private let removeFolder: (String) -> Void
    private let keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
    private let removeButton = NSButton()
    private var applying = false
    private var typeSelect: TypeSelect?
    private var folders: [WatchedFolder] = []

    init(
        selectSource: @escaping (String?) -> Void, addFolder: @escaping () -> Void,
        removeFolder: @escaping (String) -> Void,
        keyCommand: @escaping ([KeyChord]) -> CommandDispatcher.KeyOutcome
    ) {
        self.selectSource = selectSource
        self.addFolder = addFolder
        self.removeFolder = removeFolder
        self.keyCommand = keyCommand
        let libraryGroup = SidebarNode(.group, title: "Library")
        libraryGroup.children = [library]
        groups = [libraryGroup, SidebarNode(.group, title: "Playlists"), folderGroup]
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

    /// Lists `folders` and selects `source`, the library for nil.
    func show(folders: [WatchedFolder], source: String?) {
        self.folders = folders
        applying = true
        defer { applying = false }
        folderGroup.children = folders.map { folder in
            let node = SidebarNode(.folder(folder.path), title: displayName(folder.path))
            node.toolTip =
                folder.path + (folder.kind == .network ? " (network, polled)" : " (local)")
            return node
        }
        outline.reloadData()
        for group in groups { outline.expandItem(group) }
        let selected =
            source.flatMap { path in folderGroup.children.first { $0.kind == .folder(path) } }
            ?? library
        outline.selectRowIndexes([outline.row(forItem: selected)], byExtendingSelection: false)
        updateRemoveButton()
    }

    /// Selects `source` without reporting it, for Back and Forward.
    func show(source: String?) { show(folders: folders, source: source) }

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
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
        guard !applying else { return }
        switch selectedNode?.kind {
        case .folder(let path): selectSource(path)
        case .library: selectSource(nil)
        case .group, nil: break
        }
    }
}

/// A row of the source list. A class, since NSOutlineView tells items apart by identity.
private final class SidebarNode {
    enum Kind: Equatable {
        case group, library
        case folder(String)
    }

    let kind: Kind
    let title: String
    var toolTip: String?
    var children: [SidebarNode] = []

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
