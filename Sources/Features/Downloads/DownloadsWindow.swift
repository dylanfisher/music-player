import AppKit
import DisplayText
import Library
import Recommender
import Settings

/// A column of the Downloads window's table.
enum DownloadColumn: String, CaseIterable {
    case source, album, format, state, tagging, user, candidate, added

    var title: String {
        switch self {
        case .source: "Source"
        case .album: TrackColumn.album.title
        case .format: TrackColumn.codec.title
        case .state: "State"
        case .tagging: "Tagging"
        case .user: "User"
        case .candidate: "Candidate"
        case .added: "Added"
        }
    }

    var width: CGFloat {
        switch self {
        case .source: 56
        case .album: 260
        case .format: 150
        case .state: 340
        case .tagging: 90
        case .user: 120
        case .candidate: 80
        case .added: 120
        }
    }
}

/// The Downloads window (54.12): the service's jobs, a row each, with the actions on the
/// selected ones in the bar and the row's context menu (ADR 0218), Add's menu for queueing, and a status
/// line for the service and what this Mac couldn't do. It draws what it's given and reports
/// clicks; `Downloads` does the rest.
@MainActor
final class DownloadsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSWindowDelegate, NSSearchFieldDelegate
{
    static let title = "Downloads"

    let table = NSTableView()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let empty = NSTextField(labelWithString: "")
    static let noDownloads = "No downloads."
    static let noneMatch = "No downloads match the search."
    /// Filters the rows shown, leaving the service's jobs as they are.
    let search = NSSearchField()
    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// Opens slskd's web page, where Soulseek's searches and transfers can be watched.
    let slskdButton = NSButton(title: "Open slskd", target: nil, action: nil)
    static let slskdHelp = "Open slskd's web page, where the searches and transfers run."
    static let noSlskdHelp = "music-recommender hasn't said where slskd's web page is."
    /// Approve Safe Matches Automatically (ADR 0193).
    let autoApproveBox = NSButton(
        checkboxWithTitle: AppSettings().autoApproveSafeMatches.title, target: nil, action: nil)
    static let autoApproveHelp =
        "Approve each staged album tagged clean whose Approve sheet would ask nothing: no"
        + " lossy-origin finding, no old file without a new one, and no library album it"
        + " wasn't queued to replace, unless that album is tagged with its release and the"
        + " download is clearly higher quality. Upgrades replace the old files as Approve does."
        + " The rest stay staged for review."
    /// Upgrade to FLAC Automatically (ADR 0200).
    let autoUpgradeBox = NSButton(
        checkboxWithTitle: AppSettings().autoUpgrade.title, target: nil, action: nil)
    static let autoUpgradeHelp =
        "While the app is open, keep a few FLAC upgrades on their way, the most-played,"
        + " lowest-quality albums first. A copy that isn't clean is thrown away and searched"
        + " for again from another peer; approving the clean ones is Approve Safe Matches"
        + " Automatically's."
    private(set) var buttons: [DownloadAction: NSButton] = [:]
    /// The rows shown, in the window's order: those of `given` the search keeps.
    private(set) var rows: [DownloadRow] = []
    /// The rows `show` was last given.
    private var given: [DownloadRow] = []
    /// How many times the table has reloaded its rows.
    private(set) var reloads = 0
    private var canAdd = false

    /// Whether `action` applies to `row` now.
    var applies: (DownloadAction, DownloadRow) -> Bool = { _, _ in false }
    /// Hears an action on the rows it applies to, in the window's order: one row for an action
    /// that doesn't act on each.
    var act: (DownloadAction, [DownloadRow]) -> Void = { _, _ in }
    var add: (DownloadAddition) -> Void = { _ in }
    /// A row's Show Discography item, through its release; nil leaves it out.
    var discographyItem: (Int) -> NSMenuItem? = { _ in nil }
    var openSlskd: () -> Void = {}
    /// Hears Approve Safe Matches Automatically turned on or off.
    var autoApproveChanged: (Bool) -> Void = { _ in }
    /// Hears Upgrade to FLAC Automatically turned on or off.
    var autoUpgradeChanged: (Bool) -> Void = { _ in }
    /// Hears the window open and close, for the polling's pace.
    var visibilityChanged: (Bool) -> Void = { _ in }
    /// Hears the columns' widths after one changes, once `keepWidths` has set them.
    var columnsResized: (ColumnWidths) -> Void = { _ in }
    private var keepsWidths = false

    private static let added: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = Self.title
        window.minSize = NSSize(width: 960, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow) {
        let bar = NSStackView()
        bar.spacing = 8
        for action in DownloadAction.allCases {
            let button = NSButton(title: action.title, target: self, action: #selector(clicked))
            button.bezelStyle = .rounded
            button.toolTip = action.help
            button.tag = DownloadAction.allCases.firstIndex(of: action)!
            buttons[action] = button
            bar.addArrangedSubview(button)
        }
        bar.addArrangedSubview(NSView())
        slskdButton.bezelStyle = .rounded
        slskdButton.target = self
        slskdButton.action = #selector(slskdClicked)
        bar.addArrangedSubview(slskdButton)
        addButton.addItem(withTitle: "Add")
        for addition in DownloadAddition.allCases {
            addButton.addItem(withTitle: addition.title)
            addButton.lastItem?.target = self
            addButton.lastItem?.action = #selector(addChosen)
            addButton.lastItem?.tag = DownloadAddition.allCases.firstIndex(of: addition)!
        }
        addButton.autoenablesItems = false
        bar.addArrangedSubview(addButton)
        autoApproveBox.target = self
        autoApproveBox.action = #selector(autoApproveClicked)
        autoApproveBox.toolTip = Self.autoApproveHelp
        autoUpgradeBox.target = self
        autoUpgradeBox.action = #selector(autoUpgradeClicked)
        autoUpgradeBox.toolTip = Self.autoUpgradeHelp
        search.placeholderString = ListFilter.placeholder
        search.toolTip = ListFilter.help
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let boxes = NSStackView(views: [autoApproveBox, autoUpgradeBox, NSView(), search])
        boxes.spacing = 20

        for column in DownloadColumn.allCases {
            table.addColumn(
                NSUserInterfaceItemIdentifier(column.rawValue), title: column.title,
                width: column.width,
                stretches: column == .album)
        }
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = table.inListScrollView(source: self)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        empty.textColor = .secondaryLabelColor
        let page = NSStackView(views: [boxes, bar, scroll, empty, statusLabel])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for view in [boxes, bar, scroll, statusLabel] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -28).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = page
    }

    /// Shows the rows of `rows` the search keeps, keeping the selected jobs selected while
    /// they're there, and `status` below.
    func show(_ rows: [DownloadRow], status: String, canAdd: Bool) {
        self.canAdd = canAdd
        given = rows
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        for (index, _) in DownloadAddition.allCases.enumerated() {
            addButton.item(at: index + 1)?.isEnabled = canAdd
        }
        addButton.isEnabled = canAdd
        showRows()
    }

    /// Lists the rows given that the search keeps, and says when there are none.
    private func showRows() {
        let selected = Set(selectedRows.map(\.id))
        let shown = DownloadsModel.filtered(given, by: ListFilter(search.stringValue))
        if shown != rows {
            reloads += 1
            rows = shown
            table.reloadData()
            table.selectRowIndexes(
                IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }),
                byExtendingSelection: false)
        }
        empty.stringValue = given.isEmpty ? Self.noDownloads : Self.noneMatch
        empty.isHidden = !rows.isEmpty
        enableButtons()
    }

    func controlTextDidChange(_ notification: Notification) { showRows() }

    /// Enables Open slskd for `page`, slskd's web page, or says why it's off.
    func showSlskd(_ page: URL?) {
        slskdButton.isEnabled = page != nil
        slskdButton.toolTip =
            page.map { Self.slskdHelp + "\n" + $0.absoluteString } ?? Self.noSlskdHelp
    }

    @objc private func slskdClicked() { openSlskd() }

    /// Ticks Approve Safe Matches Automatically as the setting is.
    func showAutoApprove(_ on: Bool) {
        autoApproveBox.state = on ? .on : .off
    }

    @objc private func autoApproveClicked() { autoApproveChanged(autoApproveBox.state == .on) }

    func showAutoUpgrade(_ on: Bool) {
        autoUpgradeBox.state = on ? .on : .off
    }

    @objc private func autoUpgradeClicked() { autoUpgradeChanged(autoUpgradeBox.state == .on) }

    /// The rows selected, in the window's order.
    var selectedRows: [DownloadRow] {
        table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] }
    }

    /// The rows of `chosen` that `action` acts on: each it applies to, or one, `clicked`
    /// when it applies, else the first.
    private func acted(
        _ action: DownloadAction, _ chosen: [DownloadRow], clicked: DownloadRow? = nil
    ) -> [DownloadRow] {
        let applying = chosen.filter { applies(action, $0) }
        if action.actsOnEach { return applying }
        if let clicked, applying.contains(clicked) { return [clicked] }
        return Array(applying.prefix(1))
    }

    /// The rows a menu item acts on: the selection when the clicked row is in it, else the
    /// clicked row, as the Recommendations window does.
    private func menuRows(_ clicked: Int) -> [DownloadRow] {
        table.selectedRowIndexes.contains(clicked) ? selectedRows : [rows[clicked]]
    }

    private func enableButtons() {
        for (action, button) in buttons {
            button.isEnabled = !acted(action, selectedRows).isEmpty
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        let action = DownloadAction.allCases[sender.tag]
        let chosen = acted(action, selectedRows)
        if !chosen.isEmpty { act(action, chosen) }
    }

    @objc private func addChosen(_ sender: NSMenuItem) {
        guard canAdd else { return }
        add(DownloadAddition.allCases[sender.tag])
    }

    @objc private func menuChosen(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int, row < rows.count else { return }
        let action = DownloadAction.allCases[sender.tag]
        let chosen = acted(action, menuRows(row), clicked: rows[row])
        if !chosen.isEmpty { act(action, chosen) }
    }

    // MARK: - The context menu

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu, clicked: table.clickedRow) }

    /// The context menu for a click on row `clicked`, -1 for none.
    func fill(_ menu: NSMenu, clicked: Int) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        guard clicked >= 0, clicked < rows.count else { return }
        for (index, action) in DownloadAction.allCases.enumerated() {
            let item = NSMenuItem(
                title: action.title, action: #selector(menuChosen), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = clicked
            item.isEnabled = !acted(action, menuRows(clicked), clicked: rows[clicked]).isEmpty
            menu.addItem(item)
        }
        if let discography = discographyItem(rows[clicked].releaseID) {
            menu.addItem(.separator())
            menu.addItem(discography)
        }
    }

    // MARK: - The table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let column = tableColumn.flatMap({ DownloadColumn(rawValue: $0.identifier.rawValue) })
        else { return nil }
        let shown = rows[row]
        if column == .source {
            let image = NSImageView()
            image.image = NSImage(
                systemSymbolName: shown.source == .upgrade ? "arrow.up.circle" : "plus.circle",
                accessibilityDescription: text(.source, row))
            image.contentTintColor = shown.style.isDimmed ? .tertiaryLabelColor : .labelColor
            image.toolTip = tooltip(.source, row)
            return image
        }
        let label = NSTextField(labelWithString: text(column, row))
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = tooltip(column, row)
        label.textColor = color(column, shown)
        guard column == .state, let progress = shown.progress else { return label }
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = progress
        bar.controlSize = .small
        bar.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let cell = NSStackView(views: [bar, label])
        cell.spacing = 6
        return cell
    }

    /// The text of the cell in `column` of `row`.
    func text(_ column: DownloadColumn, _ row: Int) -> String {
        let shown = rows[row]
        switch column {
        case .source:
            switch shown.source {
            case .upgrade: return "Upgrade"
            case .manual: return "Queued by hand"
            case .recommendation: return DownloadSource.recommendation.title
            }
        case .album: return shown.album
        case .format: return shown.format
        case .state:
            return shown.claimedElsewhere.map { "\(shown.state) · \($0)" } ?? shown.state
        case .tagging: return shown.tagging.label
        case .user: return shown.user
        case .candidate: return shown.candidate
        case .added: return Self.added.string(from: shown.added)
        }
    }

    func tooltip(_ column: DownloadColumn, _ row: Int) -> String? {
        let shown = rows[row]
        switch column {
        case .source:
            return [text(.source, row), shown.replaces].compactMap { $0 }
                .joined(separator: ": ")
        case .album:
            let queued = DownloadRow.releaseName(shown.releaseID)
            return shown.taggedAs.map {
                "\(queued); tagged as \(DownloadRow.releaseName($0))"
            } ?? queued
        case .tagging:
            return shown.tagging.reasons.isEmpty
                ? nil : shown.tagging.reasons.joined(separator: "\n")
        case .state:
            return ([text(column, row)] + [shown.stateDetail].compactMap { $0 })
                .joined(separator: "\n")
        case .format, .user, .candidate: return text(column, row)
        case .added: return nil
        }
    }

    /// Gray at half alpha for a dimmed row; a failed state red; a tagging that warns orange.
    func color(_ column: DownloadColumn, _ row: DownloadRow) -> NSColor {
        if column == .state, row.style.isFailed { return .systemRed }
        if column == .tagging, row.style.warnsTagging { return .systemOrange }
        return row.style.isDimmed
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.5) : .labelColor
    }

    func tableViewSelectionDidChange(_ notification: Notification) { enableButtons() }

    /// Gives the columns `widths`, a column not listed keeping its own, and reports each
    /// change after. Called once the window has its frame: laid out at that size first, so the
    /// table's resizing to fit it doesn't spread the widths set after.
    func keepWidths(_ widths: ColumnWidths) {
        window?.contentView?.layoutSubtreeIfNeeded()
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

    // MARK: - The window

    func windowDidBecomeKey(_ notification: Notification) { visibilityChanged(true) }

    func windowWillClose(_ notification: Notification) { visibilityChanged(false) }
}
