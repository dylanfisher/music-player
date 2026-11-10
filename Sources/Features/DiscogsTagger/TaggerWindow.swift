import AppKit
import Discogs
import DisplayText
import Library
import Log
import Settings
import TagWriter

/// The tagger's window (51.11): the toolbar's source, scope and Analyze; Field Mapping… and the
/// choices beside it (51.23); a tab
/// per tier with its count, each an album list; the selected album's release beside its
/// tracklist, file against track; and the buttons that review it and apply a tier. With a
/// catalog it says which dump it's of, when it was imported, its size and where it is; without
/// one it says so and offers the import, and Analyze stays off for Local Catalog; the Discogs
/// API, and Both as the API alone, still analyze (ADR 0139). After an import stopped before
/// it finished it offers Resume Import and Start Over.
@MainActor
final class TaggerWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let title = "Discogs Tagger"
    /// The pasteboard type of a dragged tracklist row: the file's id.
    static let fileRowType = NSPasteboard.PasteboardType("\(bundleIdentifier).discogs-file")

    let model: TaggerModel
    let sourcePopUp = NSPopUpButton()
    let scopePopUp = NSPopUpButton()
    let analyzeButton = NSButton(title: "Analyze", target: nil, action: nil)
    let mappingButton = NSButton(title: "Field Mapping…", target: nil, action: nil)
    let keepBox = NSButton(checkboxWithTitle: "Keep existing values", target: nil, action: nil)
    let skipVideoBox = NSButton(
        checkboxWithTitle: "Skip Blu-ray, DVD and video", target: nil, action: nil)
    let sortArtistBox = NSButton(
        checkboxWithTitle: "Fill sort artist from album artist", target: nil, action: nil)
    /// The API and Both items' tooltip without a token.
    static let noTokenTip =
        "No Discogs token in config.json: only releases already tagged with an ID are looked up"
    static let importTitle = "Import Discogs Dump…"

    static let reimportTitle = "Reimport Discogs Dump…"
    let importButton = NSButton(title: TaggerWindow.importTitle, target: nil, action: nil)
    let progress = NSProgressIndicator()
    let statusLabel = NSTextField(labelWithString: "")
    let catalogLabel = NSTextField(labelWithString: "")
    let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    let catalogBox = NSStackView()
    let resumeLabel = NSTextField(labelWithString: "")
    let resumeButton = NSButton(title: "Resume Import", target: nil, action: nil)
    let startOverButton = NSButton(title: "Start Over", target: nil, action: nil)
    let resumeBox = NSStackView()
    /// The rows above the tabs, each on one line.
    private(set) var headerRows: [NSStackView] = []
    let tabs = NSSegmentedControl()
    let albumTable = NSTableView()
    /// The album list left of its divider, the tracklists right.
    let split = DividerSplitView()
    /// Set once the album list has the layout it was left at, after which each change to it
    /// is saved.
    private var keepsAlbumList = false
    /// The album's files, and beside them the release's tracks they're on: two tables of the
    /// same rows, in one scroll view and selected together, so each column's source is plain.
    let fileTable: NSTableView = SideBySideTables.Table()
    let releaseTable: NSTableView = SideBySideTables.Table()
    /// The selected album's files left out, which its rows list last, greyed.
    private(set) var leftOut: Set<Int64> = []
    /// Set while one tracklist follows the other's selection, so the other doesn't follow it
    /// back.
    private var following = false
    /// Set while `refresh` selects the model's albums in the list, so the list's notifications
    /// of it aren't taken for the user's.
    private var selectingAlbums = false
    /// Where the album list last showed the selected album, which it scrolls to when that
    /// changes.
    private var listedPlace: ListedPlace?
    private struct ListedPlace: Equatable {
        var tab: TaggerTab
        var id: Int64?
        var row: Int
    }
    let releaseTitle = NSTextField(labelWithString: "")
    let releaseLine = NSTextField(labelWithString: "")
    /// Why a Likely or Incomplete album isn't Exact, under the release's lines.
    let reasonsLine = NSTextField(labelWithString: "")
    /// The albums a combined album joins, under the reasons; hidden for any other (ADR 0179).
    let combinedLine = NSTextField(labelWithString: "")
    let otherReleasesButton = NSButton(title: "Other Releases…", target: nil, action: nil)
    let lookUpButton = NSButton(title: TaggerText.lookUp, target: nil, action: nil)
    let changesButton = NSButton(title: "View Changes…", target: nil, action: nil)
    let discogsButton = NSButton(title: openOnDiscogsTitle, target: nil, action: nil)
    let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    /// The row of buttons under the tracklists, and the one under the album list and them.
    let reviewButtons = NSStackView()
    let applyButton = NSButton(title: "", target: nil, action: nil)
    /// Get Artwork for the albums listed with a release id: their front covers from Discogs.
    let artworkButton = NSButton(title: "", target: nil, action: nil)
    let bottom = NSStackView()

    /// Writes the confirmed edits.
    var write: TaggerModel.Write = { _, _, _ in }
    /// Get Artwork over the albums given, which asks first (ADR 0172).
    var getArtwork: ([ArtworkGroup]) -> Void = { _ in }
    var mappingChosen: (DiscogsMapping, [NamedDiscogsMapping]) -> Void = { _, _ in }
    var choicesChosen: (TaggerChoices) -> Void = { _ in }
    var dumpsFolder: () -> URL? = { nil }
    var dumpsFolderChosen: (URL) -> Void = { _ in }
    /// The sheets' layouts, which each sheet opens at, and the album list's; and what saves
    /// them once a sheet closes or the album list changes.
    var sheetLayouts = TaggerSheetLayouts()
    var sheetLayoutsChosen: (TaggerSheetLayouts) -> Void = { _ in }

    /// The albums of the tab shown, in list order.
    private(set) var shownAlbums: [TaggerModel.Album] = []
    /// The selected album's tracklists side by side.
    private(set) var rows: [TrackComparison] = []
    /// An open sheet's controller, held while it shows.
    private var sheet: NSWindowController?
    /// View Release…'s sheet, over Other Releases…, held while it shows.
    private var releaseSheet: ViewReleaseSheet?
    /// Set from View Release…'s click until its sheet shows or the read fails, so a second
    /// click doesn't queue a second sheet.
    private var readingRelease = false

    init(model: TaggerModel) {
        self.model = model
        // The frame saved last, when there is one, replaces this size (ADR 0158).
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero, size: Self.openingSize(within: NSScreen.main?.visibleFrame)),
            styleMask: Self.styleMask, backing: .buffered, defer: false)
        window.title = Self.title
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build(in: window)
        model.changed = { [weak self] in self?.refresh() }
        model.failed = { [weak self] message, details in self?.alert(message, details) }
        model.write = { [weak self] files, progress, completion in
            self?.write(files, progress, completion)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// The content size the window first opens at: wide enough for the tabs' labels with
    /// five-figure counts and both tables, and no larger than the screen's `visible` frame.
    static func openingSize(within visible: NSRect?) -> NSSize {
        let wanted = NSSize(width: 1400, height: 760)
        guard let visible else { return wanted }
        let room = NSWindow.contentRect(forFrameRect: visible, styleMask: styleMask).size
        return NSSize(width: min(wanted.width, room.width), height: min(wanted.height, room.height))
    }

    private static let styleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable,
    ]

    // MARK: - Layout

    private func build(in window: NSWindow) {
        sourcePopUp.addItems(withTitles: DiscogsSource.allCases.map(\.title))
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChosen)
        scopePopUp.addItems(withTitles: shownScopes.map(\.title))
        scopePopUp.target = self
        scopePopUp.action = #selector(scopeChosen)
        for (button, action) in [
            (analyzeButton, #selector(analyzeOrStop)), (mappingButton, #selector(showMapping)),
            (importButton, #selector(chooseDumps)),
            (revealButton, #selector(revealCatalog)), (resumeButton, #selector(resumeImport)),
            (startOverButton, #selector(startImportOver)),
            (otherReleasesButton, #selector(showOtherReleases)),
            (lookUpButton, #selector(showLookUp)),
            (changesButton, #selector(showChanges)), (rejectButton, #selector(toggleRejected)),
            (discogsButton, #selector(openReleasePage)),
            (applyButton, #selector(applyAll)),
            (artworkButton, #selector(getArtworkClicked)),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        for box in [keepBox, skipVideoBox, sortArtistBox] {
            box.target = self
            box.action = #selector(choiceToggled)
        }
        keepBox.toolTip =
            "Titles, artists, numbers, credits and the date fill only empty tags,"
            + " whatever the mapping says. Off, they match Discogs as every field the mapping"
            + " replaces does: a field Discogs has no value for is cleared."
        skipVideoBox.toolTip = "Releases that are only Blu-ray, DVD or video are never candidates."
        sortArtistBox.toolTip = "Files with no sort artist get the album artist as one."
        lookUpButton.toolTip =
            "Look up the album's release by artist, title, catalog number or ID: the local"
            + " catalog first, then Discogs"
        mappingButton.toolTip =
            "Choose which tags each Discogs field writes, and how, for every album."
        importButton.toolTip =
            "Builds the local catalog from the newest Discogs dumps in a folder. Your music"
            + " files aren't touched."
        analyzeButton.keyEquivalent = "\r"
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 140).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The catalog's line with its buttons, then the controls in two rows, each of which
        // fits the window's minimum width on one line; the labels that can't truncate.
        catalogBox.setViews([catalogLabel, revealButton], in: .leading)
        catalogBox.setViews([importButton], in: .trailing)
        catalogBox.spacing = 12
        let bar = NSStackView(views: [
            label("Source:"), sourcePopUp, label("Scope:"), scopePopUp, analyzeButton, progress,
            statusLabel, NSView(),
        ])
        bar.spacing = 8
        let choices = NSStackView(views: [
            mappingButton, keepBox, skipVideoBox, sortArtistBox, NSView(),
        ])
        choices.spacing = 12
        resumeBox.setViews([resumeLabel, resumeButton, startOverButton], in: .leading)
        resumeBox.spacing = 12
        // Hidden until there's an import to resume, so the first refresh, which most often finds
        // none, doesn't lay out the whole window before it's shown.
        resumeBox.isHidden = true
        for label in [catalogLabel, resumeLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        headerRows = [catalogBox, bar, choices, resumeBox]

        tabs.segmentStyle = .automatic
        tabs.segmentCount = TaggerTab.allCases.count
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabChosen)

        let albums = taggerTable(
            albumTable, [(.album, 200), (.files, 36), (.confidence, 48), (.review, 64)],
            source: self)
        albumTable.allowsMultipleSelection = true
        // A click below the rows, or a Command-click on the one row selected, keeps it.
        albumTable.allowsEmptySelection = false
        for column in albumTable.tableColumns {
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: column.identifier.rawValue, ascending: true)
        }
        let tracks = tracklists()

        releaseTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        releaseTitle.lineBreakMode = .byTruncatingTail
        releaseLine.textColor = .secondaryLabelColor
        releaseLine.lineBreakMode = .byTruncatingTail
        reasonsLine.textColor = .systemOrange
        reasonsLine.lineBreakMode = .byTruncatingTail
        combinedLine.lineBreakMode = .byTruncatingTail
        combinedLine.isHidden = true
        // A long release or list of reasons truncates; at the default resistance it would widen
        // the window past the screen and hold it there against a drag.
        for label in [releaseTitle, releaseLine, reasonsLine, combinedLine] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        revealButton.isHidden = true
        reviewButtons.setViews(
            [otherReleasesButton, lookUpButton, changesButton, rejectButton], in: .leading)
        reviewButtons.setViews([discogsButton], in: .trailing)
        reviewButtons.spacing = 8
        let detail = NSStackView(views: [
            releaseTitle, releaseLine, reasonsLine, combinedLine, tracks, reviewButtons,
        ])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6
        detail.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        for view in [tracks, reviewButtons] {
            view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -8).isActive = true
        }

        split.isVertical = true
        split.dividerStyle = .thin
        // Only a drag is saved: a resize of the window moves the divider too, and the
        // notifications of a resize can't be told from those of a drag.
        split.dividerDragged = { [weak self] in self?.albumListChanged() }
        split.addArrangedSubview(albums)
        split.addArrangedSubview(detail)
        albums.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        // Where the divider starts; a drag moves it.
        let albumsWidth = albums.widthAnchor.constraint(equalToConstant: 340)
        albumsWidth.priority = .defaultLow
        albumsWidth.isActive = true
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

        bottom.setViews([artworkButton], in: .leading)
        bottom.setViews([applyButton], in: .trailing)
        let page = NSStackView(views: [bar, choices, catalogBox, resumeBox, tabs, split, bottom])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for view in [bar, choices, catalogBox, resumeBox, split, bottom] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -28).isActive = true
        }
        // The tables are the one view of each stack that takes the spare height, and give it
        // up first: every other row keeps its own height.
        for stack in [page, detail] {
            stack.distribution = .fill
            for view in stack.arrangedSubviews {
                let isTables = view === split || view === tracks
                view.setContentHuggingPriority(
                    isTables ? .defaultLow : .defaultHigh, for: .vertical)
                view.setContentCompressionResistancePriority(
                    isTables ? .defaultLow : .defaultHigh, for: .vertical)
            }
        }
        window.contentView = page
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    /// The files' table and the release's side by side in one scroll view, each under its
    /// heading.
    private func tracklists() -> NSStackView {
        let files = taggerTable(
            fileTable, [(.include, 24), (.number, 24), (.fileTitle, 170), (.fileTime, 48)],
            source: self)
        fileTable.tableColumns[0].headerToolTip =
            "Untick a file to leave it out of the match, as a duplicate of another release's"
        let release = taggerTable(
            releaseTable,
            [(.position, 56), (.releaseTitle, 170), (.releaseTime, 48), (.state, 84)],
            source: self)
        for table in [fileTable, releaseTable] {
            table.registerForDraggedTypes([Self.fileRowType])
            table.allowsMultipleSelection = false
        }
        fileTable.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = SideBySideTables(files, release)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let headings = NSStackView(
            views: [TaggerText.filesHeading, TaggerText.releaseHeading].map { heading in
                let title = NSTextField(labelWithString: heading)
                title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                title.textColor = .secondaryLabelColor
                return title
            })
        headings.distribution = .fillEqually
        let both = NSStackView(views: [headings, scroll])
        both.orientation = .vertical
        both.alignment = .leading
        both.spacing = 4
        for view in [headings, scroll] {
            view.widthAnchor.constraint(equalTo: both.widthAnchor).isActive = true
        }
        return both
    }

    // MARK: - Showing the model

    /// Shows the model as it is now: the catalog, the work running, the tabs, the albums and
    /// the selected album.
    func refresh() {
        // The line, its tooltip, and whether there's a catalog to reveal; nil while checking,
        // when what the last check showed stays until this one answers.
        let catalogShown: (text: String, tip: String?, isReady: Bool)?
        switch model.catalog {
        case .checking: catalogShown = nil
        case .ready(let status): catalogShown = (status.shown, status.detail, true)
        case .missing:
            let asked = model.source == .catalog ? "" : ", so the Discogs API is asked"
            catalogShown = (
                "There's no Discogs catalog on this Mac\(asked); Import Discogs Dump… builds one.",
                nil, false
            )
        case .unusable(let why):
            let text = "The Discogs catalog can't be used: \(why)."
            catalogShown = (text, text, false)
        }
        if let catalogShown {
            catalogLabel.stringValue = catalogShown.text
            catalogLabel.toolTip = catalogShown.tip
            revealButton.isHidden = !catalogShown.isReady
            importButton.title = catalogShown.isReady ? Self.reimportTitle : Self.importTitle
        } else if catalogLabel.stringValue.isEmpty {
            catalogLabel.stringValue = "Checking the Discogs catalog…"
        }
        let resumeHidden = model.unfinished == nil || model.isBusy
        if let unfinished = model.unfinished {
            resumeLabel.stringValue =
                "The import of the \(unfinished.dumpDate) Discogs dump stopped at"
                + " \(Int(unfinished.fraction * 100))%. Resume Import carries on from there; Start"
                + " Over imports the dump from its start."
            resumeLabel.toolTip = resumeLabel.stringValue
        }
        if resumeBox.isHidden != resumeHidden {
            resumeBox.isHidden = resumeHidden
            // The tables take the height the row leaves or gives back now, not at the next
            // pass that happens to come.
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        sourcePopUp.selectItem(at: DiscogsSource.allCases.firstIndex(of: model.source)!)
        sourcePopUp.isEnabled = !model.isBusy && !model.isStaged
        let tokenTip = model.hasToken() ? nil : Self.noTokenTip
        for (item, source) in zip(sourcePopUp.itemArray, DiscogsSource.allCases) {
            item.toolTip = source == .catalog ? nil : tokenTip
        }
        let scopes = shownScopes
        if scopePopUp.itemTitles != scopes.map(\.title) {
            scopePopUp.removeAllItems()
            scopePopUp.addItems(withTitles: scopes.map(\.title))
        }
        scopePopUp.selectItem(at: scopes.firstIndex(of: model.scope)!)
        scopePopUp.isEnabled = !model.isBusy
        importButton.isEnabled = !model.isBusy
        mappingButton.isEnabled = sheet == nil
        keepBox.state = model.choices.keepExistingValues ? .on : .off
        skipVideoBox.state = model.choices.skipVideo ? .on : .off
        sortArtistBox.state = model.choices.fillSortArtist ? .on : .off
        // The skip rescores with an Analyze, which can't start while one runs.
        skipVideoBox.isEnabled = !model.isBusy
        let stoppable: Bool
        switch model.activity {
        case .idle:
            stoppable = false
            if let writing = model.writeProgress {
                showWriting(writing)
            } else {
                progress.isHidden = true
                progress.isIndeterminate = false
                statusLabel.stringValue = model.status
            }
        case .analyzing(let done, let total):
            stoppable = true
            let api = model.matchProgress.flatMap { progress in
                progress.apiAlbumCount.map { (progress.apiAlbumsDone ?? 0, $0) }
            }
            if let (apiDone, apiTotal) = api {
                show(
                    apiDone, of: apiTotal,
                    "Catalog \(number(done)) of \(number(total)), then Discogs \(number(apiDone))"
                        + " of \(number(apiTotal))")
            } else {
                let what = model.runSource == .api ? "Asking Discogs about" : "Analyzing"
                show(done, of: total, "\(what) \(number(done)) of \(number(total)) albums")
            }
            if let seconds = model.matchProgress?.waitingSeconds {
                statusLabel.stringValue += "; waiting \(number(seconds)) s for Discogs's rate limit"
            }
        case .reading(let done, let total):
            stoppable = true
            show(done, of: total, "Reading \(number(done)) of \(number(total)) files")
        case .importing(let step):
            // Building the indexes is one statement that a stop can't interrupt.
            stoppable = !model.activity.isIndexing
            progress.isIndeterminate = false
            progress.isHidden = false
            progress.doubleValue = step?.fraction ?? 0
            statusLabel.stringValue = step?.text ?? "Starting the import"
        }
        let indexing = model.activity.isIndexing
        analyzeButton.title = stoppable || indexing ? "Stop" : "Analyze"
        analyzeButton.isEnabled = stoppable || model.canAnalyze

        for (index, tab) in TaggerTab.allCases.enumerated() {
            tabs.setLabel("\(tab.title) (\(number(model.count(tab))))", forSegment: index)
            tabs.setToolTip(tab.help, forSegment: index)
        }
        tabs.selectedSegment = TaggerTab.allCases.firstIndex(of: model.tab)!
        let artwork = model.artworkGroups.count
        artworkButton.title = "\(TaggerModel.artworkTitle(albums: artwork))…"
        // A staged job is written through its own journal, which covers aren't (ADR 0146).
        artworkButton.isHidden = model.isStaged
        artworkButton.isEnabled = !model.isBusy && artwork > 0

        shownAlbums = model.albums(in: model.tab)
        // An album selected that the tab doesn't list, as one an Analyze moved, gives way to
        // the tab's first, so the list never shows nothing selected while it has albums.
        var row = shownAlbums.firstIndex { $0.id == model.selectedID }
        if row == nil, let first = shownAlbums.first {
            model.selectedID = first.id
            row = 0
        }
        // Set before the reload too: a table that can't be left empty selects a row of its own
        // as it reloads.
        selectingAlbums = true
        albumTable.reloadData()
        if let row {
            // The detail's album is selected last, so it's the list's `selectedRow`.
            let others = shownAlbums.indices.filter {
                $0 != row && model.selectedIDs.contains(shownAlbums[$0].id)
            }
            if others.isEmpty {
                albumTable.selectRowIndexes([row], byExtendingSelection: false)
            } else {
                albumTable.selectRowIndexes(IndexSet(others), byExtendingSelection: false)
                albumTable.selectRowIndexes([row], byExtendingSelection: true)
            }
        }
        selectingAlbums = false
        keepSelectedInView()
        showSelected()
    }

    /// Scrolls the album list to the selected album when it is listed in another place than
    /// the list last showed it: another tab, another album, or another row after a sort or a
    /// match. A refresh that leaves it where it was doesn't scroll, so the list stays where
    /// the user scrolled it.
    private func keepSelectedInView() {
        let row = albumTable.selectedRow
        let place = row >= 0 ? ListedPlace(tab: model.tab, id: model.selectedID, row: row) : nil
        guard place != listedPlace else { return }
        listedPlace = place
        if row >= 0 { albumTable.scrollRowToVisible(row) }
    }

    /// Apply's button: all the tab's albums, or those selected when several are.
    private func showApply() {
        let canApply = TaggerModel.appliedTabs.contains(model.tab)
        applyButton.isHidden = !canApply
        applyButton.title =
            model.appliesToSelection(in: model.tab)
            ? "Apply to \(number(model.selectedAlbums.count)) Selected…"
            : "Apply to All in \(model.tab.title)…"
        applyButton.isEnabled = canApply && !model.isBusy && !model.applicable(model.tab).isEmpty
    }

    /// The writes running, beside the status bar's line: "Writing 120 tags to 20 files: 3 of
    /// 20 written", or a moving bar alone until a write reports, as a staged write never does.
    private func showWriting(_ writing: TaggerModel.WriteProgress) {
        if let report = writing.progress {
            show(0, of: 0, writing.text)
            progress.doubleValue = report.fraction
        } else {
            progress.isHidden = false
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            statusLabel.stringValue = writing.text
        }
    }

    private func show(_ done: Int, of total: Int, _ text: String) {
        progress.isIndeterminate = false
        progress.isHidden = false
        progress.doubleValue = total == 0 ? 0 : Double(done) / Double(total)
        statusLabel.stringValue = text
    }

    private func showSelected() {
        let album = model.selected
        let summary = album?.match.release?.summary
        if let summary {
            releaseTitle.stringValue = "\(summary.artist) – \(summary.title)"
            releaseLine.stringValue =
                [
                    summary.label, summary.catalogNumber, summary.country, summary.year,
                    summary.format, "Release \(summary.id)",
                    album?.match.origin == .api ? "from the Discogs API" : "",
                ]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            releaseTitle.stringValue = album == nil ? "No album selected" : "No release"
            releaseLine.stringValue =
                album == nil
                ? "" : "\(TaggerText.lookUp) searches the catalog, then Discogs."
        }
        reasonsLine.stringValue = album.flatMap { reasonsText($0.match, separator: " · ") } ?? ""
        let sources = album?.sources ?? []
        combinedLine.stringValue = sources.isEmpty ? "" : CombinedAlbum.text(sources)
        combinedLine.toolTip = sources.isEmpty ? nil : CombinedAlbum.text(sources, separator: "\n")
        combinedLine.isHidden = sources.isEmpty
        leftOut = album?.leftOut ?? []
        rows = album.map { $0.match.comparison(of: $0.album, leftOut: $0.leftOut) } ?? []
        fileTable.reloadData()
        releaseTable.reloadData()
        let reviewing = album != nil && !model.isBusy && model.rematchingID == nil
        let others = album?.match.candidates.count ?? 0
        otherReleasesButton.title = Self.otherReleasesTitle(others)
        otherReleasesButton.isEnabled = reviewing && others > 0
        lookUpButton.isEnabled = model.canLookUp && sheet == nil
        let changes = album.flatMap { $0.applied ? nil : model.changeCounts[$0.id] }
        changesButton.title = changes.map { "View \(count($0, "Change"))…" } ?? "View Changes…"
        changesButton.isEnabled = reviewing && summary != nil && album?.isRejected == false
        model.countChanges()
        discogsButton.isEnabled = summary != nil
        let reviewed = model.selectedAlbums
        rejectButton.isEnabled = reviewing && !reviewed.isEmpty
        rejectButton.title = Self.rejectTitle(reviewed)
        showApply()
    }

    /// "Reject", or "Accept" when every album selected is rejected; with the count when
    /// several are, as "Reject 3 Albums".
    static func rejectTitle(_ selected: [TaggerModel.Album]) -> String {
        let verb = !selected.isEmpty && selected.allSatisfy(\.isRejected) ? "Accept" : "Reject"
        return selected.count > 1 ? "\(verb) \(TaggerText.albums(selected.count))" : verb
    }

    /// "9 Other Releases…", "1 Other Release…", or "No Other Releases" for none, when the
    /// button is off.
    static func otherReleasesTitle(_ others: Int) -> String {
        others == 0 ? "No Other Releases" : "\(count(others, "Other Release"))…"
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === albumTable ? shownAlbums.count : rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let id = tableColumn.flatMap({ TaggerColumn(rawValue: $0.identifier.rawValue) })
        else { return nil }
        let leftOutRow = (tableView === fileTable || tableView === releaseTable) && isLeftOut(row)
        if id == .include {
            guard rows[row].fileID != nil else { return nil }
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(included))
            box.tag = row
            box.state = leftOutRow ? .off : .on
            box.isEnabled = model.canLeaveOut
            box.toolTip = leftOutRow ? "Put this file back in the match" : "Leave this file out"
            return box
        }
        let cell = NSTextField(labelWithString: text(tableView, id, row))
        cell.lineBreakMode = .byTruncatingTail
        if leftOutRow {
            cell.textColor = .tertiaryLabelColor
            if id == .state {
                cell.toolTip = TaggerText.leftOutTip
                return cell
            }
        }
        if tableView === albumTable {
            if shownAlbums[row].isRejected || shownAlbums[row].applied {
                cell.textColor = .secondaryLabelColor
            }
            let sources = shownAlbums[row].sources
            let tips = [
                sources.isEmpty ? nil : CombinedAlbum.text(sources, separator: "\n"),
                reasonsText(shownAlbums[row].match, separator: "\n"),
            ].compactMap { $0 }
            cell.toolTip = tips.isEmpty ? nil : tips.joined(separator: "\n\n")
        }
        if tableView === releaseTable, id == .state {
            cell.textColor =
                switch rows[row].state {
                case .matched: .systemGreen
                case .different: .systemOrange
                case .missing: .systemRed
                }
            cell.toolTip = rows[row].stateTip
        }
        return cell
    }

    /// A file's Include box was clicked: leaves the file out of the match, or puts it back.
    @objc private func included(_ sender: NSButton) {
        setIncluded(sender.state == .on, row: sender.tag)
    }

    /// Puts the file on `row` back in the match, or leaves it out; tests call it in place of
    /// a click.
    func setIncluded(_ included: Bool, row: Int) {
        guard row < rows.count, let fileID = rows[row].fileID, let albumID = model.selectedID
        else { return }
        Task { await model.setLeftOut(!included, fileID, of: albumID) }
    }

    /// Why `match` isn't Exact, a reason a line or `separator` apart; nil when it says nothing.
    private func reasonsText(_ match: AlbumMatch, separator: String) -> String? {
        match.reasons.isEmpty ? nil : match.reasons.map(\.text).joined(separator: separator)
    }

    /// The text of the cell in column `id` of `row`.
    func text(_ table: NSTableView, _ id: TaggerColumn, _ row: Int) -> String {
        if table === albumTable {
            let album = shownAlbums[row]
            switch id {
            case .album: return album.title
            case .files: return number(album.album.tracks.count)
            case .confidence: return album.match.confidence.map { "\($0)%" } ?? ""
            default: return album.reviewText
            }
        }
        let comparison = rows[row]
        switch id {
        case .number: return comparison.fileID == nil ? "" : String(row + 1)
        case .fileTitle: return comparison.fileTitle ?? (comparison.fileID == nil ? "" : "–")
        case .fileTime: return comparison.fileSeconds.map(clock) ?? ""
        case .position: return comparison.position ?? ""
        case .releaseTitle: return comparison.releaseTitle ?? ""
        case .releaseTime: return comparison.releaseSeconds.map { clock(Double($0)) } ?? ""
        case .include: return ""
        default: return isLeftOut(row) ? TaggerText.leftOut : comparison.stateText
        }
    }

    /// Whether the tracklists' row `row` is a file left out.
    private func isLeftOut(_ row: Int) -> Bool {
        row < rows.count && rows[row].fileID.map(leftOut.contains) == true
    }

    /// Gives the album list the pane width, column order, widths and sort it was left at, and
    /// saves each change from then on. Called once the window has its frame (ADR 0158).
    func keepAlbumList() {
        guard !keepsAlbumList, let window else { return }
        if let saved = sheetLayouts.albumList {
            window.contentView?.layoutSubtreeIfNeeded()
            split.setPosition(CGFloat(saved.paneWidth), ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            albumTable.apply(saved.table)
        }
        keepsAlbumList = true
    }

    /// Saves the album list's layout as it is now, once it has the one it was left at.
    private func albumListChanged() {
        guard keepsAlbumList, let pane = albumTable.enclosingScrollView else { return }
        let now = TaggerSheetLayouts.AlbumList(
            paneWidth: Double(pane.frame.width), table: albumTable.layout)
        guard now != sheetLayouts.albumList else { return }
        sheetLayouts.albumList = now
        sheetLayoutsChosen(sheetLayouts)
    }

    /// Saves a width the user dragged a column's edge to. The table's own resizing to fit, as
    /// the window resizes, isn't saved: it would replace the widths the user chose.
    func tableViewColumnDidResize(_ notification: Notification) {
        guard notification.object as? NSTableView === albumTable,
            (albumTable.headerView?.resizedColumn ?? -1) >= 0
        else { return }
        albumListChanged()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        if notification.object as? NSTableView === albumTable { albumListChanged() }
    }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard tableView === albumTable else { return }
        let sort = albumTable.sortDescriptors.first
        model.sortAlbums(
            by: sort.flatMap { sort in
                sort.key.flatMap(TaggerColumn.init(rawValue:)).map {
                    TaggerModel.AlbumSort(column: $0, ascending: sort.ascending)
                }
            })
        albumListChanged()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let changed = notification.object as? NSTableView else { return }
        guard changed === albumTable else {
            // A row of one tracklist is a row of the other.
            guard !following else { return }
            following = true
            (changed === fileTable ? releaseTable : fileTable).selectRowIndexes(
                changed.selectedRowIndexes, byExtendingSelection: false)
            following = false
            return
        }
        guard !selectingAlbums else { return }
        let row = albumTable.selectedRow
        let id = row >= 0 && row < shownAlbums.count ? shownAlbums[row].id : nil
        let rows = albumTable.selectedRowIndexes.filter { $0 < shownAlbums.count }
        let ids = Set(rows.map { shownAlbums[$0].id })
        guard id != model.selectedID || ids != model.selectedIDs else { return }
        model.selectedID = id
        model.selectedIDs = ids
        // A row the user selected is where they are; a later refresh scrolls only once it
        // moves.
        listedPlace = row >= 0 ? ListedPlace(tab: model.tab, id: id, row: row) : nil
        showSelected()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        guard tableView === fileTable, model.canRemap, let fileID = rows[row].fileID,
            !isLeftOut(row)
        else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setString(String(fileID), forType: Self.fileRowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tableView === fileTable || tableView === releaseTable, model.canRemap,
            row < rows.count
        else { return [] }
        tableView.setDropRow(row, dropOperation: .on)
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard
            let text = info.draggingPasteboard.string(forType: Self.fileRowType),
            let fileID = Int64(text)
        else { return false }
        return drop(fileID, onRow: row)
    }

    /// Maps the dragged file to the track on `row`: a row of the release's gets its track, a
    /// file's own row past them maps it to none.
    func drop(_ fileID: Int64, onRow row: Int) -> Bool {
        guard model.canRemap, row < rows.count, !leftOut.contains(fileID), !isLeftOut(row)
        else { return false }
        model.assign(fileID, to: rows[row].track)
        return true
    }

    // MARK: - Actions

    @objc private func sourceChosen() {
        model.chooseSource(DiscogsSource.allCases[sourcePopUp.indexOfSelectedItem])
    }

    /// The Scope pop-up's scopes: the listed ones, and the open combination while there is
    /// one, which choosing another closes (ADR 0179).
    private var shownScopes: [TaggerModel.Scope] {
        TaggerModel.Scope.listed + (model.scope == .combined ? [.combined] : [])
    }

    @objc private func scopeChosen() {
        model.scope = shownScopes[scopePopUp.indexOfSelectedItem]
        refresh()
    }

    @objc private func tabChosen() {
        model.tab = TaggerTab.allCases[tabs.selectedSegment]
        model.selectedID = model.albums(in: model.tab).first?.id
        refresh()
    }

    @objc private func analyzeOrStop() {
        model.isBusy ? model.stop() : model.analyze()
    }

    @objc private func revealCatalog() {
        guard case .ready(let status) = model.catalog else { return }
        NSWorkspace.shared.activateFileViewerSelecting([status.url])
    }

    @objc private func chooseDumps() {
        chooseFolder(startingOver: false)
    }

    /// Carries on the unfinished import from the dumps folder, or asks for the folder when
    /// it isn't where it was.
    @objc private func resumeImport() {
        importAgain(startingOver: false)
    }

    @objc private func startImportOver() {
        importAgain(startingOver: true)
    }

    private func importAgain(startingOver: Bool) {
        guard !model.isBusy else { return }
        guard let folder = dumpsFolder() else { return chooseFolder(startingOver: startingOver) }
        model.importDump(from: folder, startingOver: startingOver)
    }

    /// Asks for the dumps folder, then imports from it.
    private func chooseFolder(startingOver: Bool) {
        guard let window, !model.isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import Dump"
        panel.message =
            "Choose the folder of the Discogs dumps. The newest complete set in it is imported;"
            + " nothing in it is changed."
        panel.directoryURL = dumpsFolder()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            dumpsFolderChosen(url)
            model.importDump(from: url, startingOver: startingOver)
        }
    }

    @objc private func choiceToggled() {
        let choices = TaggerChoices(
            keepExistingValues: keepBox.state == .on, skipVideo: skipVideoBox.state == .on,
            fillSortArtist: sortArtistBox.state == .on, artwork: model.choices.artwork)
        model.setChoices(choices)
        choicesChosen(choices)
    }

    @objc private func showMapping() {
        guard let window, sheet == nil else { return }
        let mapping = MappingSheet(
            draft: MappingDraft(mapping: model.mapping, saved: model.savedMappings),
            artwork: model.choices.artwork, hasToken: model.hasToken())
        present(mapping, over: window) { [weak self] in
            guard let self, let draft = mapping.result else { return }
            mappingChosen(draft.mapping, draft.saved)
            guard mapping.artwork != model.choices.artwork else { return }
            var choices = model.choices
            choices.artwork = mapping.artwork
            model.setChoices(choices)
            choicesChosen(choices)
        }

    }

    @objc private func showOtherReleases() {
        guard let window, let album = model.selected, sheet == nil else { return }
        Task {
            let candidates: [(summary: ReleaseSummary, score: Double?)]
            do {
                candidates = try await model.candidates()
            } catch {
                return alert("The other releases couldn't be read", ["\(error)"])
            }
            let releases = ReleasesSheet(
                candidates: candidates, chosen: album.match.releaseID,
                title: album.title)
            releases.viewRelease = { [self, weak releases] id in
                guard let over = releases?.window else { return }
                viewRelease(id, over: over)
            }
            present(releases, over: window) { [self] in
                guard let id = releases.result, id != album.match.releaseID else { return }
                Task { await model.choose(id, for: album.id) }
            }
        }
    }

    /// Look Up Release…: the release list with a search above it, filled from the album's tags;
    /// nothing is asked until Search. A release used is chosen as Other Releases' is.
    @objc private func showLookUp() {
        guard let window, let album = model.selected, model.canLookUp, sheet == nil else {
            return
        }
        let releases = ReleasesSheet(
            candidates: [], chosen: album.match.releaseID, title: album.title,
            lookUp: { [model] in try await model.lookUp($0) }, query: model.lookUpQuery())
        releases.viewRelease = { [self, weak releases] id in
            guard let over = releases?.window else { return }
            viewRelease(id, over: over)
        }
        present(releases, over: window) { [self] in
            guard let id = releases.result, id != album.match.releaseID else { return }
            Task { await model.choose(id, for: album.id, from: releases.origin) }
        }
    }

    /// Shows release `id` over Other Releases…, which stays open under it.
    private func viewRelease(_ id: Int, over sheetWindow: NSWindow) {
        guard releaseSheet == nil, !readingRelease else { return }
        readingRelease = true
        Task {
            defer { readingRelease = false }
            let detail: ReleaseDetail?
            do {
                detail = try await model.release(id)
            } catch {
                // Over the tagger when Other Releases was closed while the release was read.
                let over = sheetWindow.sheetParent != nil ? sheetWindow : nil
                return alert("The release couldn't be read", ["\(error)"], over: over)
            }
            // Other Releases was closed while the release was read.
            guard sheetWindow.sheetParent != nil else { return }
            guard let detail else {
                return alert(
                    "The release couldn't be read", ["The catalog has no release \(id)."],
                    over: sheetWindow)
            }
            let shown = ViewReleaseSheet(release: detail)
            releaseSheet = shown
            begin(shown, over: sheetWindow) { [self] in releaseSheet = nil }
        }
    }

    /// What Open on Discogs opens a page with; tests stand in for the browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @objc private func openReleasePage() {
        guard let id = model.selected?.match.releaseID else { return }
        openOnDiscogs(id, through: openURL)
    }

    @objc private func showChanges() {
        guard let window, let album = model.selected, let releaseID = album.match.releaseID,
            sheet == nil
        else { return }
        Task {
            let set: AlbumChangeSet
            let problems: [String]
            do {
                guard let read = try await model.changeSet(for: album.id) else { return }
                (set, problems) = read
            } catch {
                return alert("The album's files couldn't be read", ["\(error)"])
            }
            if !problems.isEmpty {
                return alert("\(problems.count) of the album's files can't be read", problems)
            }
            let changes = ChangesSheet(
                set: set, excluded: album.excluded, coverExcluded: album.coverExcluded,
                title: album.title, releaseID: releaseID)
            present(changes, over: window) { [self] in
                guard let answer = changes.result else { return }
                model.setExcluded(
                    answer.excluded, coverExcluded: answer.coverExcluded, for: album.id)

                if answer.apply { apply([album.id]) }
            }
        }
    }

    /// Rejects the albums selected, or accepts them when they're all rejected.
    @objc private func toggleRejected() {
        let selected = model.selectedAlbums
        guard !selected.isEmpty else { return }
        let rejecting = !selected.allSatisfy(\.isRejected)
        Task { await model.setRejected(rejecting, selected.map(\.id)) }
    }

    @objc private func getArtworkClicked() { getArtwork(model.artworkGroups) }

    @objc private func applyAll() {
        apply(model.applicable(model.tab).map(\.id))
    }

    /// Reads the albums' files, works out what Apply writes, and asks once, with the counts,
    /// before any is written (ADR 0133).
    private func apply(_ albumIDs: [Int64]) {
        guard let window, !albumIDs.isEmpty else { return }
        Task {
            guard let plan = await model.plan(albumIDs) else { return }
            guard !plan.files.isEmpty else {
                return alert(
                    "Nothing to write",
                    plan.problems.isEmpty
                        ? ["The albums' files already hold what the mapping writes."]
                        : plan.problems)
            }
            let (message, detail) = TaggerModel.confirmation(plan, staged: model.isStaged)
            let question = NSAlert()
            question.messageText = message
            question.informativeText = detail
            question.addButton(withTitle: "Apply")
            question.addButton(withTitle: "Cancel")
            question.beginSheetModal(for: window) { [self] response in
                guard response == .alertFirstButtonReturn else { return }
                model.apply(plan)
            }
        }
    }

    /// Shows `controller`'s window as a sheet over `window`, calling `ended` once it closes.
    private func present(
        _ controller: some TaggerSheet, over window: NSWindow, ended: @escaping () -> Void
    ) {
        guard controller.window != nil else { return }
        sheet = controller
        refresh()
        begin(controller, over: window) { [weak self] in
            self?.sheet = nil
            ended()
            self?.refresh()
        }
    }

    /// Shows `controller` as a sheet over `window` at the layout it was left at, and saves its
    /// layout once it closes, before `ended`.
    private func begin(
        _ controller: some TaggerSheet, over window: NSWindow, ended: @escaping () -> Void
    ) {
        guard let sheetWindow = controller.window else { return }
        controller.apply(sheetLayouts, room: window.screen?.visibleFrame.size)
        window.beginSheet(sheetWindow) { [weak self, weak controller] _ in
            if let self, let controller {
                sheetLayouts = controller.recorded(in: sheetLayouts)
                sheetLayoutsChosen(sheetLayouts)
            }
            ended()
        }
    }

    /// Shows the problems over `over`, the tagger's window unless a sheet of it is up and
    /// would hide the alert.
    private func alert(_ message: String, _ details: [String], over: NSWindow? = nil) {
        guard let window = over ?? window else { return }
        showProblems(message, details, over: window)
    }
}

/// A sheet over the tagger's window, which ends itself with its answer set.
@MainActor
protocol TaggerSheet: NSWindowController {
    /// Which of the saved layouts is this sheet's.
    static var layoutKind: TaggerSheetKind { get }
    /// The table whose column widths and sort the layout keeps.
    var table: NSTableView { get }
}

extension NSWindowController {
    /// Ends the sheet this controller's window is.
    func endSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}

/// A split view that says when the user has dragged its divider.
final class DividerSplitView: NSSplitView {
    /// Called as a drag of the divider ends.
    var dividerDragged: () -> Void = {}

    /// A click on the split view itself is on a divider; AppKit tracks its drag here until the
    /// mouse goes up.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        dividerDragged()
    }
}
