import AppKit

/// A list of choices, each with a checkbox, that the user drags into order: the status bar's
/// parts, left to right from the top. The ticked ones come first, in the setting's order, and
/// only they can be dragged, among themselves, so the order shown is the order kept; the rest
/// follow in the schema's order.
@MainActor
final class ChecklistView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let rowPoints = 22.0
    static let widthPoints = 260.0
    private static let rowType = NSPasteboard.PasteboardType("musicplayer.checklist-row")

    /// Called with every item, in order, after the user ticks one or drags one.
    var changed: ([GeneralModel.ChecklistItem]) -> Void = { _ in }
    var items: [GeneralModel.ChecklistItem] = [] {
        didSet {
            table.reloadData()
            height.constant = Self.rowPoints * Double(items.count) + 2
        }
    }
    let table = NSTableView()
    private let height: NSLayoutConstraint

    init(title: String) {
        let scroll = NSScrollView()
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("choice"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowPoints - table.intercellSpacing.height
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel(title)
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Self.widthPoints), height,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let item = items[row]
        let box = NSButton(
            checkboxWithTitle: item.choice.title, target: self, action: #selector(ticked(_:)))
        box.state = item.isOn ? .on : .off
        box.tag = row
        return box
    }

    @objc private func ticked(_ box: NSButton) {
        guard items.indices.contains(box.tag) else { return }
        var changed = items
        changed[box.tag].isOn = box.state == .on
        self.changed(changed)
    }

    /// How many items are ticked, which are the first ones.
    private var tickedCount: Int { items.prefix { $0.isOn }.count }

    /// Moves the ticked item at `from` to before the item at `to`, as a drop in the gap above
    /// row `to` asks, and reports the new order. `to` is at most just after the last ticked one.
    func move(from: Int, to: Int) {
        guard from < tickedCount, (0...tickedCount).contains(to), to != from, to != from + 1
        else { return }
        var moved = items
        let item = moved.remove(at: from)
        moved.insert(item, at: to > from ? to - 1 : to)
        changed(moved)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        guard row < tickedCount else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, row <= tickedCount else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.rowType),
            let from = Int(text)
        else { return false }
        move(from: from, to: row)
        return true
    }
}
