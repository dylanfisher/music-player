import AppKit
import Discogs

/// Other Releases… (51.11, after YATE's release list): the album's candidates with filters by
/// artist, title, country, label and format, sorted by any column's header. Choosing one
/// rescores the album with it; View Release… shows one first.
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

    /// Searches the catalog, then Discogs, for Look Up Release.
    typealias LookUp = (ReleaseQuery) async throws -> ReleaseLookup

    private(set) var candidates: [(summary: ReleaseSummary, score: Double?)]
    let chosen: Int?
    let fields: [Filter: NSSearchField]
    let table = NSTableView()
    static let layoutKind = TaggerSheetKind.otherReleases
    /// The candidates the filters leave, in the order the sort gives.
    private(set) var shown: [(summary: ReleaseSummary, score: Double?)]
    /// The release chosen; nil for Cancel.
    private(set) var result: Int?
    /// Where the releases listed came from: the API only for a look-up Discogs answered.
    private(set) var origin = MatchOrigin.catalog
    /// Shows the release given, over this sheet.
    var viewRelease: (Int) -> Void = { _ in }
    private var texts: [Filter: String] = [:]
    let heading = NSTextField(labelWithString: "")
    private let albumTitle: String

    /// Look Up Release's search, with its fields; nil for Other Releases.
    private let lookUp: LookUp?
    let artistField = NSTextField()
    let titleField = NSTextField()
    let catalogNumberField = NSTextField()
    let releaseField = NSTextField()
    let searchButton = NSButton(title: "Search", target: nil, action: nil)
    let searching = NSProgressIndicator()
    /// The search running, which a new one or Cancel stops.
    private var search: Task<Void, Never>?
    /// Counts the searches started, so only the latest one's answer is shown.
    private var searches = 0

    /// Other Releases… over `candidates`, or with `lookUp`, Look Up Release, which lists what
    /// its search finds, its fields filled from `query`.
    init(
        candidates: [(summary: ReleaseSummary, score: Double?)], chosen: Int?, title: String,
        lookUp: LookUp? = nil, query: ReleaseQuery = ReleaseQuery()
    ) {
        self.candidates = candidates
        self.chosen = chosen
        self.lookUp = lookUp
        albumTitle = title
        shown = candidates
        fields = Dictionary(uniqueKeysWithValues: Filter.allCases.map { ($0, NSSearchField()) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 300)
        super.init(window: window)
        artistField.stringValue = query.artist
        titleField.stringValue = query.title
        catalogNumberField.stringValue = query.catalogNumber
        releaseField.stringValue = query.release
        build(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow) {
        heading.stringValue =
            lookUp == nil
            ? "\(candidates.count) releases found for \(albumTitle)"
            : "Look up a release for \(albumTitle): the catalog first, then Discogs"
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
                (.country, 80), (.year, 44), (.format, 160), (.tracks, 48),
            ],
            source: self)
        for column in table.tableColumns {
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: column.identifier.rawValue, ascending: true)
        }
        table.target = self
        table.doubleAction = #selector(choose)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let viewButton = NSButton(
            title: "View Release…", target: self, action: #selector(showRelease))
        let use = NSButton(title: "Use Release", target: self, action: #selector(choose))
        // Return searches in Look Up Release; a double click still uses a release.
        if lookUp == nil { use.keyEquivalent = "\r" }
        let buttons = NSStackView(views: [NSView(), cancel, viewButton, use])
        var rows: [NSView] = [heading]
        if lookUp != nil { rows.append(queryRow()) }
        rows += [filters, scroll, buttons]
        let page = NSStackView(views: rows)
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in rows.dropFirst() {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = page
        if let chosen, let row = shown.firstIndex(where: { $0.summary.id == chosen }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    /// Look Up Release's fields and Search, on one line.
    private func queryRow() -> NSStackView {
        let placed: [(NSTextField, String)] = [
            (artistField, TaggerColumn.artist.title), (titleField, TaggerColumn.title.title),
            (catalogNumberField, TaggerColumn.catalogNumber.title),
            (releaseField, "Release ID or URL"),
        ]
        for (field, placeholder) in placed {
            field.placeholderString = placeholder
            field.lineBreakMode = .byTruncatingTail
            field.cell?.isScrollable = true
        }
        releaseField.toolTip =
            "A release ID or URL is looked up alone; the other fields are ignored"
        searchButton.target = self
        searchButton.action = #selector(startSearch)
        searchButton.keyEquivalent = "\r"
        searching.style = .spinning
        searching.controlSize = .small
        searching.isDisplayedWhenStopped = false
        let fields = NSStackView(views: placed.map(\.0))
        fields.distribution = .fillEqually
        let row = NSStackView(views: [fields, searching, searchButton])
        fields.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    /// What the fields ask for.
    var query: ReleaseQuery {
        ReleaseQuery(
            artist: artistField.stringValue, title: titleField.stringValue,
            catalogNumber: catalogNumberField.stringValue, release: releaseField.stringValue)
    }

    @objc private func startSearch() {
        // Ending the edit commits the field's text first.
        window?.makeFirstResponder(nil)
        search?.cancel()
        search = Task { await runSearch() }
    }

    /// Searches for what the fields ask, and lists what's found, saying where it came from.
    func runSearch() async {
        guard let lookUp else { return }
        let query = query
        guard !query.isEmpty else {
            heading.stringValue = TaggerText.lookUpEmpty
            return NSSound.beep()
        }
        searches += 1
        let mine = searches
        searchButton.isEnabled = false
        searching.startAnimation(nil)
        heading.stringValue = TaggerText.searching
        // A newer search owns the button, the spinner and the heading.
        defer {
            if mine == searches {
                searchButton.isEnabled = true
                searching.stopAnimation(nil)
            }
        }
        let found: ReleaseLookup
        do {
            found = try await lookUp(query)
        } catch {
            if mine == searches, !(error is CancellationError) {
                heading.stringValue = "The search stopped: \(error)"
            }
            return
        }
        guard mine == searches else { return }
        origin = found.origin
        candidates = found.releases.map { (summary: $0.summary, score: Optional($0.score)) }
        heading.stringValue = TaggerText.found(found, byIDAlone: query.ignoresOtherFields)
        showCandidates()
    }

    /// Keeps the candidates whose every filtered column holds its field's text, ignoring case
    /// and accents, in the sort's order.
    func filter(_ texts: [Filter: String]) {
        self.texts = texts
        showCandidates()
    }

    /// Sorts by the column `column`; the header's click does the same.
    func sort(by column: TaggerColumn, ascending: Bool) {
        table.sortDescriptors = [
            NSSortDescriptor(key: column.rawValue, ascending: ascending)
        ]
    }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        showCandidates()
    }

    /// The candidates the filters leave, sorted by the table's sort descriptor; their found
    /// order when it has none, and between equal values.
    private func showCandidates() {
        let kept = candidates.enumerated().filter { _, candidate in
            texts.allSatisfy { filter, text in
                text.isEmpty
                    || filter.value(candidate.summary).range(
                        of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let descriptor = table.sortDescriptors.first
        let column = descriptor.flatMap { $0.key.flatMap(TaggerColumn.init(rawValue:)) }
        shown = kept.sorted { a, b in
            guard let column, let descriptor else { return a.offset < b.offset }
            let order = Self.compare(a.element, b.element, by: column)
            if order == .orderedSame { return a.offset < b.offset }
            return descriptor.ascending
                ? order == .orderedAscending : order == .orderedDescending
        }
        .map(\.element)
        table.reloadData()
    }

    /// How two candidates compare in `column`: numbers as numbers, the chosen release's fit,
    /// which has no score, above every scored one; the rest as Finder sorts names.
    private static func compare(
        _ a: (summary: ReleaseSummary, score: Double?),
        _ b: (summary: ReleaseSummary, score: Double?), by column: TaggerColumn
    ) -> ComparisonResult {
        func numbers<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
            x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        }
        switch column {
        case .score: return numbers(a.score ?? .infinity, b.score ?? .infinity)
        case .tracks: return numbers(a.summary.trackCount, b.summary.trackCount)
        case .year: return numbers(Int(a.summary.year) ?? 0, Int(b.summary.year) ?? 0)
        default: return text(a.summary, column).localizedStandardCompare(text(b.summary, column))
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        filter(fields.mapValues(\.stringValue))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let column = tableColumn.flatMap({ TaggerColumn(rawValue: $0.identifier.rawValue) })
        else { return nil }
        let value = text(row, column)
        let cell = NSTextField(labelWithString: value)
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = value
        if shown[row].summary.id == chosen {
            cell.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        }
        return cell
    }

    /// The text of `row`'s cell in `column`.
    func text(_ row: Int, _ column: TaggerColumn) -> String {
        let (summary, score) = shown[row]
        if column == .score { return score.map { "\(Int(($0 * 100).rounded()))%" } ?? "chosen" }
        return Self.text(summary, column)
    }

    private static func text(_ summary: ReleaseSummary, _ column: TaggerColumn) -> String {
        switch column {
        case .artist: summary.artist
        case .title: summary.title
        case .label: summary.label
        case .catalogNumber: summary.catalogNumber
        case .country: summary.country
        case .year: summary.year
        case .tracks: String(summary.trackCount)
        default: summary.format
        }
    }

    @objc private func cancel() {
        search?.cancel()
        endSheet()
    }

    @objc private func showRelease() {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return NSSound.beep() }
        viewRelease(shown[table.selectedRow].summary.id)
    }

    @objc private func choose() {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return NSSound.beep() }
        result = shown[table.selectedRow].summary.id
        endSheet()
    }
}
