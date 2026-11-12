import AppKit
import Discogs
import DisplayText
import Recommender
import Settings

/// The Recommendations window (ADR 0205): the list pop-up, the view and the albums' filters,
/// a table of the rows, the selected row's reasons, what is pending or wrong, and the list's
/// facts. It draws what it's given and reports what the user does; `Recommendations` does the
/// rest.
@MainActor
final class RecommendationsWindow: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSMenuDelegate, NSWindowDelegate, NSTokenFieldDelegate
{
    static let title = "Recommendations"

    let listButton = NSPopUpButton()
    let viewControl = NSSegmentedControl(
        labels: ["Albums", "Artists"], trackingMode: .selectOne, target: nil, action: nil)
    let missingBox = NSButton(checkboxWithTitle: "Missing", target: nil, action: nil)
    static let missingHelp =
        "Only albums by an artist of the list's albums: the library's artists for Library, the"
        + " seed albums' for a seed."
    let stylesField = NSTokenField()
    let yearFromField = NSTextField()
    let yearToField = NSTextField()
    let labelsField = NSTokenField()
    let table = RecommendationTable()
    let notInterestedButton = NSButton(
        title: verdictTitle(.notInterested), target: nil, action: nil)
    let alreadyHaveButton = NSButton(title: verdictTitle(.alreadyHave), target: nil, action: nil)
    let markedButton = NSButton(title: "Marked…", target: nil, action: nil)
    let downloadButton = NSButton(title: "Download…", target: nil, action: nil)
    let discogsButton = NSButton(title: openOnDiscogsTitle, target: nil, action: nil)
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let actionButton = NSButton(title: "", target: nil, action: nil)
    let factsLabel = NSTextField(labelWithString: "")
    /// The rows shown, in the list's order.
    private(set) var rows: [RecommendationRow] = []
    private(set) var query = RecommendationQuery()
    /// The state of each release's newest download job, by release id.
    private(set) var downloads: [Int: String] = [:]
    private var seeds: [RecommendationQuery.Seed] = []
    private var action: (() -> Void)?

    /// Hears a change of list, view or filter.
    var queryChosen: (RecommendationQuery) -> Void = { _ in }
    /// Hears Not Interested or Already Have on rows.
    var markChosen: ([RecommendationRow], FeedbackMark.Verdict) -> Void = { _, _ in }
    /// Hears Download… on rows.
    var downloadChosen: ([RecommendationRow]) -> Void = { _ in }
    /// Hears Open on Discogs on a row.
    var discogsChosen: (RecommendationRow) -> Void = { _ in }
    /// Hears Marked… clicked.
    var showMarked: () -> Void = {}
    /// The row selected when a mark took rows out, selected again as the rows come back.
    private var place: Int?
    /// Hears the table scrolled to its last row.
    var reachedEnd: () -> Void = {}
    var visibilityChanged: (Bool) -> Void = { _ in }
    /// Hears the columns' widths after one changes, once `keepWidths` has set them.
    var columnsResized: (ColumnWidths) -> Void = { _ in }
    private var keepsWidths = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = Self.title
        window.minSize = NSSize(width: 900, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow) {
        listButton.target = self
        listButton.action = #selector(listChosen)
        viewControl.target = self
        viewControl.action = #selector(viewChosen)
        missingBox.target = self
        missingBox.action = #selector(filterEdited)
        missingBox.toolTip = Self.missingHelp
        stylesField.placeholderString = RecommendationColumn.styles.title
        stylesField.delegate = self
        stylesField.target = self
        stylesField.action = #selector(filterEdited)
        labelsField.placeholderString = "Labels, from a row's menu"
        labelsField.delegate = self
        labelsField.target = self
        labelsField.action = #selector(filterEdited)
        for field in [yearFromField, yearToField] {
            field.target = self
            field.action = #selector(filterEdited)
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }
        yearFromField.placeholderString = "From"
        yearToField.placeholderString = "To"
        for field in [stylesField, labelsField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        }
        let bar = NSStackView(views: [
            listButton, viewControl, missingBox, stylesField,
            NSTextField(labelWithString: "Years"), yearFromField, yearToField, labelsField,
        ])
        bar.spacing = 8
        notInterestedButton.action = #selector(notInterestedClicked)
        notInterestedButton.toolTip = "Leave the selected albums out of every list (⌫)."
        alreadyHaveButton.action = #selector(alreadyHaveClicked)
        alreadyHaveButton.toolTip = "Leave the selected albums out of every list, as had."
        markedButton.action = #selector(markedClicked)
        markedButton.toolTip = "Every album marked, to remove a mark."
        downloadButton.action = #selector(downloadClicked)
        downloadButton.toolTip = "Queue the selected albums in Downloads."
        discogsButton.action = #selector(discogsClicked)
        discogsButton.toolTip = "Open the first selected album's page on Discogs."
        let buttons = [
            notInterestedButton, alreadyHaveButton, downloadButton, discogsButton, markedButton,
        ]
        let actions = NSStackView(views: [
            notInterestedButton, alreadyHaveButton, downloadButton, discogsButton, NSView(),
            markedButton,
        ])
        actions.spacing = 8
        for button in buttons {
            button.bezelStyle = .rounded
            button.target = self
        }
        table.deleteKey = { [weak self] in self?.notInterestedClicked() }

        for column in RecommendationColumn.allCases {
            table.addColumn(
                NSUserInterfaceItemIdentifier(column.rawValue), title: column.title,
                width: CGFloat(column.width), stretches: column == .why)
            table.tableColumns.last?.isHidden = column.hiddenByDefault
        }
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        let scroll = table.inListScrollView(source: self)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        let status = NSStackView(views: [progress, messageLabel, actionButton])
        status.spacing = 8
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.lineBreakMode = .byTruncatingTail
        factsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let page = NSStackView(views: [bar, actions, status, scroll, detailLabel, factsLabel])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for view in [actions, scroll, detailLabel, factsLabel] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -28).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = page
    }

    /// Shows the states of the download jobs, by release id, in the Download column.
    func show(downloads: [Int: String]) {
        guard downloads != self.downloads else { return }
        self.downloads = downloads
        let column = table.column(
            withIdentifier: NSUserInterfaceItemIdentifier(RecommendationColumn.download.rawValue))
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [column])
    }

    /// Shows the list: `rows` of `query`, the pop-up's `seeds`, `message` with a spinner while
    /// `pending`, and the button `action` names when there is something to do.
    func show(
        rows: [RecommendationRow], query: RecommendationQuery,
        seeds: [RecommendationQuery.Seed], pending: Bool, message: String?,
        action: (title: String, run: () -> Void)?, facts: String?
    ) {
        if seeds != self.seeds {
            self.seeds = seeds
            listButton.removeAllItems()
            listButton.addItems(withTitles: seeds.map(seedTitle))
        }
        if let index = seeds.firstIndex(of: query.seed) { listButton.selectItem(at: index) }
        viewControl.selectedSegment = query.show == .albums ? 0 : 1
        let albums = query.show == .albums
        for control in [missingBox, stylesField, yearFromField, yearToField, labelsField] {
            control.isEnabled = albums
        }
        if query != self.query {
            self.query = query
            missingBox.state = query.filters.missing ? .on : .off
            stylesField.objectValue = query.filters.styles
            yearFromField.stringValue = query.filters.yearFrom.map(String.init) ?? ""
            yearToField.stringValue = query.filters.yearTo.map(String.init) ?? ""
            labelsField.objectValue = query.filters.labels.map { $0.name ?? "\($0.id)" }
            for column in table.tableColumns
            where column.identifier.rawValue == RecommendationColumn.albums.rawValue {
                column.isHidden = albums
            }
        }
        if rows != self.rows {
            self.rows = rows
            table.reloadData()
            if let place, !rows.isEmpty {
                table.selectRowIndexes([min(place, rows.count - 1)], byExtendingSelection: false)
            }
        }
        if !pending { place = nil }
        if pending { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        self.action = action?.run
        actionButton.title = action?.title ?? ""
        actionButton.isHidden = action == nil
        factsLabel.stringValue = facts ?? ""
        showDetail()
    }

    private func showDetail() {
        let row = table.selectedRow
        detailLabel.stringValue = row >= 0 && row < rows.count ? reasonsText(rows[row].album) : ""
        for button in [notInterestedButton, alreadyHaveButton, downloadButton, discogsButton] {
            button.isEnabled = !selectedRows.isEmpty
        }
    }

    /// The rows selected, in the list's order.
    var selectedRows: [RecommendationRow] {
        table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] }
    }

    /// The rows a menu item acts on: the selection when the clicked row is in it, else the
    /// clicked row.
    private func menuRows(_ clicked: Int) -> [RecommendationRow] {
        table.selectedRowIndexes.contains(clicked) ? selectedRows : [rows[clicked]]
    }

    private func mark(_ marked: [RecommendationRow], _ verdict: FeedbackMark.Verdict) {
        guard !marked.isEmpty else { return }
        place = table.selectedRowIndexes.first
        markChosen(marked, verdict)
    }

    @objc private func notInterestedClicked() { mark(selectedRows, .notInterested) }

    @objc private func alreadyHaveClicked() { mark(selectedRows, .alreadyHave) }

    @objc private func markedClicked() { showMarked() }

    @objc private func downloadClicked() {
        let chosen = selectedRows
        if !chosen.isEmpty { downloadChosen(chosen) }
    }

    /// Open on Discogs: the first selected row's page, as Open Discogs Release opens the
    /// first selected track's.
    @objc func discogsClicked() {
        if let first = selectedRows.first { discogsChosen(first) }
    }

    @objc private func discogsMenuChosen(_ sender: NSMenuItem) {
        guard let clicked = sender.representedObject as? Int, clicked < rows.count else { return }
        discogsChosen(rows[clicked])
    }

    @objc private func downloadMenuChosen(_ sender: NSMenuItem) {
        guard let clicked = sender.representedObject as? Int, clicked < rows.count else { return }
        downloadChosen(menuRows(clicked))
    }

    @objc private func verdictChosen(_ sender: NSMenuItem) {
        guard let clicked = sender.representedObject as? Int, clicked < rows.count else { return }
        mark(menuRows(clicked), sender.tag == 0 ? .notInterested : .alreadyHave)
    }

    @objc private func actionClicked() { action?() }

    @objc private func listChosen() {
        let index = listButton.indexOfSelectedItem
        guard index >= 0, index < seeds.count else { return }
        var chosen = query
        chosen.seed = seeds[index]
        queryChosen(chosen)
    }

    @objc private func viewChosen() {
        var chosen = query
        chosen.show = viewControl.selectedSegment == 0 ? .albums : .artists
        queryChosen(chosen)
    }

    /// Reads the filters from their fields; a year that isn't a number is left out.
    @objc private func filterEdited() {
        var chosen = query
        chosen.filters.missing = missingBox.state == .on
        chosen.filters.styles = (stylesField.objectValue as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        chosen.filters.yearFrom = Int(
            yearFromField.stringValue.trimmingCharacters(in: .whitespaces))
        chosen.filters.yearTo = Int(yearToField.stringValue.trimmingCharacters(in: .whitespaces))
        let names = Set(labelsField.objectValue as? [String] ?? [])
        chosen.filters.labels = query.filters.labels.filter {
            names.contains($0.name ?? "\($0.id)")
        }
        if chosen != query { queryChosen(chosen) }
    }

    /// Adds `style` or `label`, from a row's menu, to the filters.
    @objc private func styleChosen(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String else { return }
        var chosen = query
        if !chosen.filters.styles.contains(style) { chosen.filters.styles.append(style) }
        queryChosen(chosen)
    }

    @objc private func labelChosen(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, index < rows.count,
            let label = rows[index].album.label
        else { return }
        var chosen = query
        if !chosen.filters.labels.contains(label) { chosen.filters.labels.append(label) }
        queryChosen(chosen)
    }

    @objc private func columnToggled(_ sender: NSMenuItem) {
        guard let column = table.tableColumns.first(where: { $0.title == sender.title })
        else { return }
        column.isHidden.toggle()
    }

    // MARK: - The menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === table.headerView?.menu {
            for column in table.tableColumns
            where column.identifier.rawValue != RecommendationColumn.albums.rawValue
                || query.show == .artists
            {
                let item = NSMenuItem(
                    title: column.title, action: #selector(columnToggled), keyEquivalent: "")
                item.target = self
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
            return
        }
        let clicked = table.clickedRow
        guard clicked >= 0, clicked < rows.count else { return }
        for (tag, button) in [notInterestedButton, alreadyHaveButton].enumerated() {
            let item = NSMenuItem(
                title: button.title, action: #selector(verdictChosen), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = clicked
            menu.addItem(item)
        }
        let download = NSMenuItem(
            title: downloadButton.title, action: #selector(downloadMenuChosen), keyEquivalent: "")
        download.target = self
        download.representedObject = clicked
        menu.addItem(download)
        let discogs = NSMenuItem(
            title: discogsButton.title, action: #selector(discogsMenuChosen), keyEquivalent: "")
        discogs.target = self
        discogs.representedObject = clicked
        menu.addItem(discogs)
        guard query.show == .albums else { return }
        menu.addItem(.separator())
        let album = rows[clicked].album
        for style in album.styles.compactMap(\.name) {
            let item = NSMenuItem(
                title: "Filter by Style \(terminalSafe(style))", action: #selector(styleChosen),
                keyEquivalent: "")
            item.target = self
            item.representedObject = style
            menu.addItem(item)
        }
        if let label = album.label {
            let item = NSMenuItem(
                title: "Filter by Label \(terminalSafe(label.name ?? "\(label.id)"))",
                action: #selector(labelChosen), keyEquivalent: "")
            item.target = self
            item.representedObject = clicked
            menu.addItem(item)
        }
    }

    // MARK: - The table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard
            let column = tableColumn.flatMap({
                RecommendationColumn(rawValue: $0.identifier.rawValue)
            })
        else { return nil }
        if row == rows.count - 1 { reachedEnd() }
        let album = rows[row].album
        let label = NSTextField(
            labelWithString: column.text(
                rows[row], download: album.releaseID.flatMap { downloads[$0] }))
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = column == .why ? reasonsText(album) : label.stringValue
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showDetail() }

    /// Gives the columns `widths`, a column not listed keeping its own, and reports each
    /// change after, as the Downloads window does.
    func keepWidths(_ widths: ColumnWidths) {
        window?.contentView?.layoutSubtreeIfNeeded()
        table.setWidths(widths.widths)
        keepsWidths = true
    }

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

/// The window's table, which hears ⌫ for Not Interested.
final class RecommendationTable: NSTableView {
    var deleteKey: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{7F}",
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        {
            deleteKey()
        } else {
            super.keyDown(with: event)
        }
    }
}
