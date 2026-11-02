import AppKit
import Commands
import Settings

/// Settings ▸ Watched Folders: each folder with its kind and how often it's rescanned, buttons to
/// add and remove one, and Rescan for the selected folders or Rescan All, from buttons or the
/// table's context menu.
@MainActor
final class FoldersPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation
{
    private enum Column: String, CaseIterable {
        case location, kind, rescans

        var title: String {
            switch self {
            case .location: "Folder"
            case .kind: "Kind"
            case .rescans: "Rescans"
            }
        }

        var width: CGFloat {
            switch self {
            case .location: 380
            case .kind: 80
            case .rescans: 100
            }
        }
    }

    private let model: GeneralModel
    private let row: GeneralModel.Row
    private let actions: SettingsActions
    let table = NSTableView()
    let removeButton = NSButton()
    let rescanButton = NSButton()
    private(set) var folders: [GeneralModel.Folder] = []

    init(model: GeneralModel, actions: SettingsActions) {
        guard let row = model.foldersRow else {
            preconditionFailure("the schema has no watched folders setting")
        }
        self.model = model
        self.row = row
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// The setting's key, which the palette opens this pane for.
    var key: String { row.key }

    override func loadView() {
        let summary = NSTextField(wrappingLabelWithString: row.summary)
        summary.textColor = .secondaryLabelColor
        for column in Column.allCases {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(row.title)
        let menu = NSMenu()
        menu.addItem(
            withTitle: Self.rescanTitle, action: #selector(rescanClicked), keyEquivalent: "")
        menu.addItem(
            withTitle: AppCommands.title(of: .rescanNow), action: #selector(rescanNow),
            keyEquivalent: "")
        for item in menu.items { item.target = self }
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "Add…", target: self, action: #selector(addFolder))
        removeButton.title = "Remove…"
        removeButton.target = self
        removeButton.action = #selector(removeFolder)
        rescanButton.title = Self.rescanTitle
        rescanButton.target = self
        rescanButton.action = #selector(rescanSelected)
        let rescanAll = NSButton(
            title: AppCommands.title(of: .rescanNow), target: self, action: #selector(rescanNow))
        for button in [add, removeButton, rescanButton, rescanAll] { button.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [add, removeButton, spacer, rescanButton, rescanAll])

        let stack = NSStackView(views: [summary, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [summary, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: GeneralPane.width),
            scroll.heightAnchor.constraint(equalToConstant: 220),
        ])
        view = stack
        reload()
    }

    /// Lists the folders as the config file has them now.
    func reload() {
        folders = model.folders(row.key)
        table.reloadData()
        updateButtons()
    }

    private static let rescanTitle = "Rescan"

    /// Remove takes one folder, since it asks about it by name; Rescan takes any number.
    private func updateButtons() {
        removeButton.isEnabled = table.selectedRowIndexes.count == 1
        rescanButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    /// The rows the context menu acts on: the clicked row, with the rest of the selection when
    /// it's among them.
    private var clickedRows: IndexSet {
        let clicked = table.clickedRow
        guard clicked >= 0 else { return table.selectedRowIndexes }
        return table.selectedRowIndexes.contains(clicked) ? table.selectedRowIndexes : [clicked]
    }

    @objc private func addFolder() { actions.addFolder() }

    @objc private func removeFolder() {
        guard folders.indices.contains(table.selectedRow) else { return }
        actions.removeFolder(table.selectedRow)
    }

    @objc private func rescanNow() { actions.rescanNow() }

    @objc private func rescanSelected() { rescan(table.selectedRowIndexes) }

    @objc private func rescanClicked() { rescan(clickedRows) }

    private func rescan(_ rows: IndexSet) {
        let positions = rows.filter(folders.indices.contains)
        guard !positions.isEmpty else { return }
        actions.rescanFolders(positions)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(rescanClicked) || !clickedRows.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { folders.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id) else {
            return nil
        }
        let folder = folders[row]
        let text =
            switch column {
            case .location: folder.location
            case .kind: folder.kind
            case .rescans: folder.rescans
            }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}
