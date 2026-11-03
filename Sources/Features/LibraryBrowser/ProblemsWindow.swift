import AppKit

/// Every folder the watcher couldn't scan, every file with a stored warning or failure, and
/// what the health check shown and the last import found, a row each, with buttons for what
/// can be done about the rows selected (ADR 0059). ⌘C copies them as text.
@MainActor
final class ProblemsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Called with a button's action and the rows selected when it was clicked.
    var act: (ProblemAction, [Problem]) -> Void = { _, _ in }

    let window: NSPanel
    let table = CopyingTableView()
    private(set) var rows: [Problem] = []
    private(set) var buttons: [ProblemAction: NSButton] = [:]
    private let empty = NSTextField(labelWithString: "No problems.")

    override init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered,
            defer: true)
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("problemLine"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 16
        table.dataSource = self
        table.delegate = self
        table.lines = { [weak self] in
            guard let self else { return [] }
            return table.selectedRowIndexes.map { self.rows[$0].line }
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let bar = NSStackView()
        for action in ProblemAction.allCases {
            let button = NSButton(title: action.title, target: self, action: #selector(clicked))
            button.tag = ProblemAction.allCases.firstIndex(of: action)!
            buttons[action] = button
            bar.addArrangedSubview(button)
        }
        bar.addArrangedSubview(empty)
        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.title = "Library Problems"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        // A panel hides with the app by default; the list stays up while the owner checks Finder.
        window.hidesOnDeactivate = false
        window.center()
    }

    /// Lists `problems` and brings the window forward.
    func show(_ problems: [Problem]) {
        update(problems)
        window.makeKeyAndOrderFront(nil)
    }

    /// Lists `problems` if the window is open, keeping the rows selected that are still there.
    func refresh(_ problems: [Problem]) {
        guard window.isVisible else { return }
        update(problems)
    }

    private func update(_ problems: [Problem]) {
        let selected = Set(table.selectedRowIndexes.map { rows[$0].line })
        rows = problems
        table.reloadData()
        table.selectRowIndexes(
            IndexSet(rows.indices.filter { selected.contains(rows[$0].line) }),
            byExtendingSelection: false)
        empty.isHidden = !rows.isEmpty
        enableButtons()
    }

    var selected: [Problem] { table.selectedRowIndexes.map { rows[$0] } }

    private func enableButtons() {
        for (action, button) in buttons { button.isEnabled = action.applies(to: selected) }
    }

    @objc private func clicked(_ sender: NSButton) {
        let action = ProblemAction.allCases[sender.tag]
        let selected = selected
        guard action.applies(to: selected) else { return }
        act(action, selected)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let label = NSTextField(labelWithString: rows[row].line)
        label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = rows[row].line
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { enableButtons() }
}

/// A table whose Copy puts the selected rows' lines on the pasteboard, one a line.
final class CopyingTableView: NSTableView {
    var lines: () -> [String] = { [] }

    @objc func copy(_ sender: Any?) {
        let text = lines()
        guard !text.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.joined(separator: "\n"), forType: .string)
    }
}
