import AppKit
import Discogs

/// Other Releases… (51.11, after YATE's release list): the album's candidates with filters by
/// artist, title, country, label and format. Choosing one rescores the album with it.
@MainActor
final class ReleasesSheet: NSWindowController, TaggerSheet, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    enum Filter: CaseIterable {
        case artist, title, country, label, format

        var column: TaggerColumn {
            switch self {
            case .artist: .artist
            case .title: .title
            case .country: .country
            case .label: .label
            case .format: .format
            }
        }

        func value(_ summary: ReleaseSummary) -> String {
            switch self {
            case .artist: summary.artist
            case .title: summary.title
            case .country: summary.country
            case .label: summary.label + " " + summary.catalogNumber
            case .format: summary.format
            }
        }
    }

    let candidates: [(summary: ReleaseSummary, score: Double?)]
    let chosen: Int?
    let fields: [Filter: NSSearchField]
    let table = NSTableView()
    /// The candidates the filters leave, in their order.
    private(set) var shown: [(summary: ReleaseSummary, score: Double?)]
    /// The release chosen; nil for Cancel.
    private(set) var result: Int?

    init(candidates: [(summary: ReleaseSummary, score: Double?)], chosen: Int?, title: String) {
        self.candidates = candidates
        self.chosen = chosen
        shown = candidates
        fields = Dictionary(uniqueKeysWithValues: Filter.allCases.map { ($0, NSSearchField()) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 300)
        super.init(window: window)
        build(in: window, title: title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow, title: String) {
        let heading = NSTextField(
            labelWithString: "\(candidates.count) releases found for \(title)")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingTail
        let filters = NSStackView(
            views: Filter.allCases.map { filter in
                let field = fields[filter]!
                field.placeholderString = filter.column.title
                field.delegate = self
                return field
            })
        filters.distribution = .fillEqually
        let scroll = taggerTable(
            table,
            [
                (.score, 44), (.artist, 160), (.title, 180), (.label, 140), (.catalogNumber, 90),
                (.country, 80), (.year, 44), (.format, 160),
            ],
            source: self)
        table.target = self
        table.doubleAction = #selector(choose)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let use = NSButton(title: "Use Release", target: self, action: #selector(choose))
        use.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, use])
        let page = NSStackView(views: [heading, filters, scroll, buttons])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [filters, scroll, buttons] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = page
        if let chosen, let row = shown.firstIndex(where: { $0.summary.id == chosen }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    /// Keeps the candidates whose every filtered column holds its field's text, ignoring case
    /// and accents.
    func filter(_ texts: [Filter: String]) {
        shown = candidates.filter { candidate in
            texts.allSatisfy { filter, text in
                text.isEmpty
                    || filter.value(candidate.summary).range(
                        of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        table.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) {
        filter(fields.mapValues(\.stringValue))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let (summary, score) = shown[row]
        let text =
            switch tableColumn.flatMap({ TaggerColumn(rawValue: $0.identifier.rawValue) }) {
            case .score: score.map { "\(Int(($0 * 100).rounded()))%" } ?? "chosen"
            case .artist: summary.artist
            case .title: summary.title
            case .label: summary.label
            case .catalogNumber: summary.catalogNumber
            case .country: summary.country
            case .year: summary.year
            default: summary.format
            }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = text
        if summary.id == chosen { cell.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return cell
    }

    @objc private func cancel() { endSheet() }

    @objc private func choose() {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return NSSound.beep() }
        result = shown[table.selectedRow].summary.id
        endSheet()
    }
}
