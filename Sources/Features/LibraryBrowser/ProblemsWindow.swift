import AppKit
import DisplayText
import Settings
import WindowPlacement

/// Every folder the watcher couldn't scan, every file with a stored warning or failure, and
/// what the health check shown and the last import found, a row each, with buttons for what
/// can be done about the rows selected, or all of them (ADR 0059). A column for each part of a
/// problem, sortable by any (ADR 0175). ⌘C copies the rows selected as text.
@MainActor
final class ProblemsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let title = "Library Problems"

    /// Called with a button's action and the rows it acts on: those selected when it was
    /// clicked, or every row for Dismiss All.
    var act: (ProblemAction, [Problem]) -> Void = { _, _ in }
    /// Called with the columns' widths after the user resizes one.
    var columnsResized: (ColumnWidths) -> Void = { _ in }

    let window: NSWindow
    let table = CopyingTableView()
    /// The rows as listed, in the order the sort gives.
    private(set) var rows: [Problem] = []
    private(set) var buttons: [ProblemAction: NSButton] = [:]
    private let empty = NSTextField(labelWithString: "No problems.")
    /// Whether the widths kept have been applied, after which a resize is reported.
    private var keepsWidths = false

    override init() {
        // A document window, not a panel: it goes behind the app's other windows and other
        // apps' while the owner works through the list (ADR 0175).
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: true)
        super.init()
        for column in ProblemColumn.allCases {
            table.addColumn(
                NSUserInterfaceItemIdentifier(column.rawValue), title: column.title,
                width: column.width, stretches: column == .detail)
            table.tableColumns.last?.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue, ascending: true)
        }
        table.allowsMultipleSelection = true
        table.lines = { [weak self] in
            guard let self else { return [] }
            return table.selectedRowIndexes.map { self.rows[$0].line }
        }
        let scroll = table.inListScrollView(source: self)
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
        window.title = Self.title
        window.contentView = stack
        window.isReleasedWhenClosed = false
    }

    /// Lists `problems` and brings the window forward, the first time at the frame and column
    /// widths kept.
    func show(_ problems: [Problem], widths: ColumnWidths = ColumnWidths()) {
        update(problems)
        window.keepsFrame(as: window.title)
        if !keepsWidths { keepWidths(widths) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Lists `problems` if the window is open, keeping the rows selected that are still there.
    func refresh(_ problems: [Problem]) {
        guard window.isVisible else { return }
        update(problems)
    }

    /// The rows in the order given, before a sort.
    private var given: [Problem] = []

    private func update(_ problems: [Problem]) {
        given = problems
        relist()
        empty.isHidden = !rows.isEmpty
    }

    /// Lists `given` in the sort chosen, keeping the rows selected that are still there.
    private func relist() {
        let selected = Set(table.selectedRowIndexes.map { rows[$0].line })
        rows = sorted(given)
        table.reloadData()
        table.selectRowIndexes(
            IndexSet(rows.indices.filter { selected.contains(rows[$0].line) }),
            byExtendingSelection: false)
        enableButtons()
    }

    /// `problems` by the column the table sorts by, as Finder compares names; rows that
    /// compare the same keep their order.
    private func sorted(_ problems: [Problem]) -> [Problem] {
        guard let sort = table.sortDescriptors.first,
            let column = sort.key.flatMap(ProblemColumn.init(rawValue:))
        else { return problems }
        return problems.enumerated().sorted { one, other in
            switch column.text(one.element).localizedStandardCompare(column.text(other.element)) {
            case .orderedSame: one.offset < other.offset
            case .orderedAscending: sort.ascending
            case .orderedDescending: !sort.ascending
            }
        }.map(\.element)
    }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) { relist() }

    var selected: [Problem] { table.selectedRowIndexes.map { rows[$0] } }

    private func enableButtons() {
        for (action, button) in buttons {
            button.isEnabled = action.applies(to: action.rows(selected: selected, all: rows))
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        let action = ProblemAction.allCases[sender.tag]
        let acted = action.rows(selected: selected, all: rows)
        guard action.applies(to: acted) else { return }
        act(action, acted)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let column = tableColumn.flatMap({ ProblemColumn(rawValue: $0.identifier.rawValue) })
        else { return nil }
        let problem = rows[row]
        let label = NSTextField(labelWithString: column.text(problem))
        label.lineBreakMode = column == .folder ? .byTruncatingMiddle : .byTruncatingTail
        label.toolTip =
            switch column {
            case .file, .folder: problem.path
            case .kind, .track, .detail: problem.line
            }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { enableButtons() }

    /// Gives the columns `widths`, a column not listed keeping its own, and reports each
    /// change after. Laid out at the window's size first, so the table's fitting to it doesn't
    /// spread the widths set after.
    private func keepWidths(_ widths: ColumnWidths) {
        window.contentView?.layoutSubtreeIfNeeded()
        table.setWidths(widths.widths)
        keepsWidths = true
    }

    /// The columns' widths as they are now.
    var columnWidths: ColumnWidths {
        ColumnWidths(table.widthsByColumn)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        if keepsWidths { columnsResized(columnWidths) }
    }
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
