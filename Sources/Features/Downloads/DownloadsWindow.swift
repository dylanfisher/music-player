import AppKit
import Library
import Recommender
import Settings

/// A column of the Downloads window's table.
enum DownloadColumn: String, CaseIterable {
    case source, album, format, state, tagging, candidate, added

    var title: String {
        switch self {
        case .source: "Source"
        case .album: TrackColumn.album.title
        case .format: TrackColumn.codec.title
        case .state: "State"
        case .tagging: "Tagging"
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
        case .candidate: 150
        case .added: 120
        }
    }
}

/// The Downloads window (54.12): the service's jobs, a row each, with the actions on the
/// selected one in the bar and the row's context menu, Add's menu for queueing, and a status
/// line for the service and what this Mac couldn't do. It draws what it's given and reports
/// clicks; `Downloads` does the rest.
@MainActor
final class DownloadsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSWindowDelegate
{
    static let title = "Downloads"

    let table = NSTableView()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let empty = NSTextField(labelWithString: "No downloads.")
    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// Opens slskd's web page, where Soulseek's searches and transfers can be watched.
    let slskdButton = NSButton(title: "Open slskd", target: nil, action: nil)
    static let slskdHelp = "Open slskd's web page, where the searches and transfers run."
    static let noSlskdHelp = "music-recommender hasn't said where slskd's web page is."
    private(set) var buttons: [DownloadAction: NSButton] = [:]
    /// The rows shown, in the window's order.
    private(set) var rows: [DownloadRow] = []
    /// How many times the table has reloaded its rows.
    private(set) var reloads = 0
    private var canAdd = false

    /// Whether `action` applies to `row` now.
    var applies: (DownloadAction, DownloadRow) -> Bool = { _, _ in false }
    var act: (DownloadAction, DownloadRow) -> Void = { _, _ in }
    var add: (DownloadAddition) -> Void = { _ in }
    var openSlskd: () -> Void = {}
    /// Hears the window open and close, for the polling's pace.
    var visibilityChanged: (Bool) -> Void = { _ in }

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

        for column in DownloadColumn.allCases {
            addColumn(
                to: table, column.rawValue, title: column.title, width: column.width,
                stretches: column == .album)
        }
        table.rowHeight = 20
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = listTable(table, source: self)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        empty.textColor = .secondaryLabelColor
        let page = NSStackView(views: [bar, scroll, empty, statusLabel])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for view in [bar, scroll, statusLabel] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -28).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = page
    }

    /// Shows `rows`, keeping the selected job selected while it's there, and `status` below.
    func show(_ rows: [DownloadRow], status: String, canAdd: Bool) {
        let selected = selectedRow?.id
        self.canAdd = canAdd
        if rows != self.rows {
            reloads += 1
            self.rows = rows
            table.reloadData()
            if let selected, let row = rows.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        empty.isHidden = !rows.isEmpty
        for (index, _) in DownloadAddition.allCases.enumerated() {
            addButton.item(at: index + 1)?.isEnabled = canAdd
        }
        addButton.isEnabled = canAdd
        enableButtons()
    }

    /// Enables Open slskd for `page`, slskd's web page, or says why it's off.
    func showSlskd(_ page: URL?) {
        slskdButton.isEnabled = page != nil
        slskdButton.toolTip =
            page.map { Self.slskdHelp + "\n" + $0.absoluteString } ?? Self.noSlskdHelp
    }

    @objc private func slskdClicked() { openSlskd() }

    var selectedRow: DownloadRow? {
        let row = table.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    private func enableButtons() {
        for (action, button) in buttons {
            button.isEnabled = selectedRow.map { applies(action, $0) } ?? false
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        let action = DownloadAction.allCases[sender.tag]
        guard let row = selectedRow, applies(action, row) else { return }
        act(action, row)
    }

    @objc private func addChosen(_ sender: NSMenuItem) {
        guard canAdd else { return }
        add(DownloadAddition.allCases[sender.tag])
    }

    @objc private func menuChosen(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int, row < rows.count else { return }
        let action = DownloadAction.allCases[sender.tag]
        guard applies(action, rows[row]) else { return }
        act(action, rows[row])
    }

    // MARK: - The context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let clicked = table.clickedRow
        guard clicked >= 0, clicked < rows.count else { return }
        for (index, action) in DownloadAction.allCases.enumerated() {
            let item = NSMenuItem(
                title: action.title, action: #selector(menuChosen), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = clicked
            item.isEnabled = applies(action, rows[clicked])
            menu.addItem(item)
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
            case .recommendation: return "Recommendation"
            }
        case .album: return shown.album
        case .format: return shown.format
        case .state:
            return shown.claimedElsewhere.map { "\(shown.state) · \($0)" } ?? shown.state
        case .tagging: return shown.tagging.label
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
        case .album: return DownloadRow.releaseName(shown.releaseID)
        case .tagging:
            return shown.tagging.reasons.isEmpty
                ? nil : shown.tagging.reasons.joined(separator: "\n")
        case .state:
            return ([text(column, row)] + [shown.stateDetail].compactMap { $0 })
                .joined(separator: "\n")
        case .format, .candidate: return text(column, row)
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

    // MARK: - The window

    func windowDidBecomeKey(_ notification: Notification) { visibilityChanged(true) }

    func windowWillClose(_ notification: Notification) { visibilityChanged(false) }
}
