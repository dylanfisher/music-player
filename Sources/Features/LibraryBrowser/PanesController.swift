import AppKit
import Commands
import KeyChord
import Library
import Settings

/// The genre, artist and album panes, side by side, each with an All row first.
@MainActor
final class PanesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: BrowserModel
    private(set) var tables: [BrowserModel.Pane: KeyTableView] = [:]
    private let select: (BrowserModel.Pane, Int64?) -> Void
    private let keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
    /// Set while selections are set from the model, so they don't count as clicks.
    private var applying = false
    private var typeSelect: TypeSelect? = TypeSelect()

    init(
        model: BrowserModel, select: @escaping (BrowserModel.Pane, Int64?) -> Void,
        keyCommand: @escaping ([KeyChord]) -> CommandDispatcher.KeyOutcome
    ) {
        self.model = model
        self.select = select
        self.keyCommand = keyCommand
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        // Equal widths, as in Swinsian; the panes don't resize apart from each other.
        let row = NSStackView()
        row.distribution = .fillEqually
        row.spacing = 1
        for pane in BrowserModel.Pane.allCases {
            let table = KeyTableView()
            table.takeKey = { [weak self] event in self?.takeKey(event, in: pane) ?? false }
            let column = NSTableColumn(identifier: entryIdentifier)
            column.title = pane.title
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.style = .fullWidth
            table.rowHeight = 18
            table.dataSource = self
            table.delegate = self
            tables[pane] = table
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            row.addArrangedSubview(scroll)
        }
        view = row
    }

    func reload() {
        typeSelect?.reset()
        applying = true
        defer { applying = false }
        for pane in BrowserModel.Pane.allCases {
            guard let table = tables[pane] else { continue }
            table.reloadData()
            let entries = self.entries(pane)
            let row =
                selected(pane).flatMap { id in entries.firstIndex { $0.id == id } }
                .map { $0 + 1 } ?? 0
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    private func takeKey(_ event: NSEvent, in pane: BrowserModel.Pane) -> Bool {
        routeKey(event, typeSelect: &typeSelect, keyCommand: keyCommand) { [weak self] query in
            guard let self else { return }
            // Row 0 is All.
            guard
                let index = TypeSelect.firstIndex(
                    startingWith: query, in: self.entries(pane).lazy.map(\.name))
            else {
                NSSound.beep()
                return
            }
            self.selectRow(index + 1, in: pane)
        }
    }

    /// Moves a pane's selection. Panes select one row, so an extending move is a plain one.
    func move(_ move: RowMove, in pane: BrowserModel.Pane) {
        guard let table = tables[pane] else { return }
        let row = table.selectedRow >= 0 ? table.selectedRow : nil
        let next = ListSelection(rows: row.map { [$0] } ?? [], cursor: row, anchor: row).moved(
            move, extending: false, rowCount: table.numberOfRows,
            pageRows: Int(table.visibleRect.height / max(1, table.rowHeight)))
        if let cursor = next.cursor { selectRow(cursor, in: pane) }
    }

    private func selectRow(_ row: Int, in pane: BrowserModel.Pane) {
        guard let table = tables[pane] else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func pane(of table: NSTableView) -> BrowserModel.Pane? {
        tables.first { $0.value === table }?.key
    }

    private func entries(_ pane: BrowserModel.Pane) -> [BrowserEntry] {
        switch pane {
        case .genre: model.genres
        case .artist: model.artists
        case .album: model.albums
        }
    }

    private func selected(_ pane: BrowserModel.Pane) -> Int64? {
        switch pane {
        case .genre: model.filter.genre
        case .artist: model.filter.artist
        case .album: model.filter.album
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        pane(of: tableView).map { entries($0).count + 1 } ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let pane = pane(of: tableView) else { return nil }
        let identifier = entryIdentifier
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingTail
                text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
        let entries = self.entries(pane)
        cell.textField?.stringValue =
            row == 0 ? pane.allTitle(entries.count) : entries[row - 1].name
        cell.textField?.font =
            row == 0
            ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying, let table = notification.object as? NSTableView,
            let pane = pane(of: table)
        else { return }
        typeSelect?.reset()
        let row = table.selectedRow
        let entries = self.entries(pane)
        // No selection, or the All row, means All.
        select(pane, row > 0 && row <= entries.count ? entries[row - 1].id : nil)
    }
}

/// Each pane's one column, and its cells.
private let entryIdentifier = NSUserInterfaceItemIdentifier("entry")

extension BrowserModel.Pane {
    public var title: String {
        switch self {
        case .genre: TrackColumn.genre.title
        case .artist: TrackColumn.artist.title
        case .album: TrackColumn.album.title
        }
    }

    /// "All (12 Genres)".
    func allTitle(_ count: Int) -> String {
        let noun = count == 1 ? title : title + "s"
        return "All (\(count) \(noun))"
    }
}
