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
/// one it says so and offers the import, and Analyze stays off. After an import stopped before
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
    let trackTable = NSTableView()
    let releaseTitle = NSTextField(labelWithString: "")
    let releaseLine = NSTextField(labelWithString: "")
    /// Why a Likely or Incomplete album isn't Exact, under the release's lines.
    let reasonsLine = NSTextField(labelWithString: "")
    let otherReleasesButton = NSButton(title: "Other Releases…", target: nil, action: nil)
    let changesButton = NSButton(title: "View Changes…", target: nil, action: nil)
    let discogsButton = NSButton(title: openOnDiscogsTitle, target: nil, action: nil)
    let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    /// The row of buttons under the tracklists, and the one under the album list and them.
    let reviewButtons = NSStackView()
    let applyButton = NSButton(title: "", target: nil, action: nil)
    let bottom = NSStackView()

    /// Writes the confirmed edits.
    var write: ([(path: String, edit: TagEdit)], @escaping (Set<String>) -> Void) -> Void = {
        _, _ in
    }
    var mappingChosen: (DiscogsMapping, [NamedDiscogsMapping]) -> Void = { _, _ in }
    var choicesChosen: (TaggerChoices) -> Void = { _ in }
    var dumpsFolder: () -> URL? = { nil }
    var dumpsFolderChosen: (URL) -> Void = { _ in }
    /// The sheets' layouts, which each sheet opens at, and what saves them once one closes.
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = Self.title
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.title)
        super.init(window: window)
        build(in: window)
        model.changed = { [weak self] in self?.refresh() }
        model.failed = { [weak self] message, details in self?.alert(message, details) }
        model.write = { [weak self] files, completion in self?.write(files, completion) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    // MARK: - Layout

    private func build(in window: NSWindow) {
        sourcePopUp.autoenablesItems = false
        for source in TaggerModel.Source.allCases {
            sourcePopUp.addItem(withTitle: source.title)
            sourcePopUp.lastItem?.isEnabled = source.isAvailable
            if !source.isAvailable { sourcePopUp.lastItem?.toolTip = "Comes with the Discogs API" }
        }
        scopePopUp.addItems(withTitles: TaggerModel.Scope.allCases.map(\.title))
        scopePopUp.target = self
        scopePopUp.action = #selector(scopeChosen)
        for (button, action) in [
            (analyzeButton, #selector(analyzeOrStop)), (mappingButton, #selector(showMapping)),
            (importButton, #selector(chooseDumps)),
            (revealButton, #selector(revealCatalog)), (resumeButton, #selector(resumeImport)),
            (startOverButton, #selector(startImportOver)),
            (otherReleasesButton, #selector(showOtherReleases)),
            (changesButton, #selector(showChanges)), (rejectButton, #selector(toggleRejected)),
            (discogsButton, #selector(openReleasePage)),
            (applyButton, #selector(applyAll)),
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
            + " whatever the mapping says."
        skipVideoBox.toolTip = "Releases that are only Blu-ray, DVD or video are never candidates."
        sortArtistBox.toolTip = "Files with no sort artist get the album artist as one."
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
        for label in [catalogLabel, resumeLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        headerRows = [catalogBox, bar, choices, resumeBox]

        tabs.segmentStyle = .automatic
        tabs.segmentCount = MatchTier.allCases.count
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabChosen)

        let albums = taggerTable(
            albumTable, [(.album, 200), (.files, 36), (.review, 64)], source: self)
        let tracks = taggerTable(
            trackTable,
            [
                (.number, 24), (.fileTitle, 170), (.fileTime, 48), (.position, 56),
                (.releaseTitle, 170), (.releaseTime, 48), (.state, 20),
            ],
            source: self)
        trackTable.registerForDraggedTypes([Self.fileRowType])
        trackTable.setDraggingSourceOperationMask(.move, forLocal: true)

        releaseTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        releaseTitle.lineBreakMode = .byTruncatingTail
        releaseLine.textColor = .secondaryLabelColor
        releaseLine.lineBreakMode = .byTruncatingTail
        reasonsLine.textColor = .systemOrange
        reasonsLine.lineBreakMode = .byTruncatingTail
        revealButton.isHidden = true
        reviewButtons.setViews([otherReleasesButton, changesButton, rejectButton], in: .leading)
        reviewButtons.setViews([discogsButton], in: .trailing)
        reviewButtons.spacing = 8
        let detail = NSStackView(views: [
            releaseTitle, releaseLine, reasonsLine, tracks, reviewButtons,
        ])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6
        detail.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        for view in [tracks, reviewButtons] {
            view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -8).isActive = true
        }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(albums)
        split.addArrangedSubview(detail)
        albums.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        // Where the divider starts; a drag moves it.
        let albumsWidth = albums.widthAnchor.constraint(equalToConstant: 340)
        albumsWidth.priority = .defaultLow
        albumsWidth.isActive = true
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

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
            catalogShown = (
                "There's no Discogs catalog on this Mac; Import Discogs Dump… builds one.", nil,
                false
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
        sourcePopUp.selectItem(at: TaggerModel.Source.allCases.firstIndex(of: model.source)!)
        scopePopUp.selectItem(at: TaggerModel.Scope.allCases.firstIndex(of: model.scope)!)
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
            progress.isHidden = true
            statusLabel.stringValue = model.status
        case .analyzing(let done, let total):
            stoppable = true
            show(done, of: total, "Analyzing \(number(done)) of \(number(total)) albums")
        case .reading(let done, let total):
            stoppable = true
            show(done, of: total, "Reading \(number(done)) of \(number(total)) files")
        case .importing(let step):
            // Building the indexes is one statement that a stop can't interrupt.
            stoppable = !model.activity.isIndexing
            progress.isHidden = false
            progress.doubleValue = step?.fraction ?? 0
            statusLabel.stringValue = step?.text ?? "Starting the import"
        }
        let indexing = model.activity.isIndexing
        analyzeButton.title = stoppable || indexing ? "Stop" : "Analyze"
        analyzeButton.isEnabled = stoppable || model.canAnalyze

        for (index, tier) in MatchTier.allCases.enumerated() {
            tabs.setLabel("\(tier.title) (\(number(model.count(tier))))", forSegment: index)
        }
        tabs.selectedSegment = MatchTier.allCases.firstIndex(of: model.tab)!
        let canApply = TaggerModel.appliedTiers.contains(model.tab)
        applyButton.isHidden = !canApply
        applyButton.title = "Apply to All in \(model.tab.title)…"
        applyButton.isEnabled = canApply && !model.isBusy && !model.applicable(model.tab).isEmpty

        shownAlbums = model.albums(in: model.tab)
        albumTable.reloadData()
        if let row = shownAlbums.firstIndex(where: { $0.id == model.selectedID }) {
            albumTable.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            albumTable.deselectAll(nil)
        }
        showSelected()
    }

    private func show(_ done: Int, of total: Int, _ text: String) {
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
                ]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            releaseTitle.stringValue = album == nil ? "No album selected" : "No release"
            releaseLine.stringValue =
                album == nil
                ? "" : "Other Releases… lists what the catalog found, if anything."
        }
        reasonsLine.stringValue = album.flatMap { reasonsText($0.match, separator: " · ") } ?? ""
        rows = album.map { $0.match.comparison(of: $0.album) } ?? []
        trackTable.reloadData()
        let reviewing = album != nil && !model.isBusy
        otherReleasesButton.isEnabled = reviewing
        changesButton.isEnabled = reviewing && summary != nil && album?.isRejected == false
        discogsButton.isEnabled = summary != nil
        rejectButton.isEnabled = reviewing
        rejectButton.title = album?.isRejected == true ? "Accept" : "Reject"
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
        let cell = NSTextField(labelWithString: text(tableView, id, row))
        cell.lineBreakMode = .byTruncatingTail
        if tableView === albumTable {
            if shownAlbums[row].isRejected || shownAlbums[row].applied {
                cell.textColor = .secondaryLabelColor
            }
            cell.toolTip = reasonsText(shownAlbums[row].match, separator: "\n")
        }
        if tableView === trackTable, id == .state {
            cell.textColor =
                switch rows[row].state {
                case .matched: .systemGreen
                case .different: .systemOrange
                case .missing: .systemRed
                }
        }
        return cell
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
            case .album: return albumTitle(album.album)
            case .files: return number(album.album.tracks.count)
            default:
                if album.applied { return "Written" }
                switch album.review {
                case .rejected: return "Rejected"
                case .chosen: return "Chosen"
                case nil: return ""
                }
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
        default: return comparison.state.mark
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === albumTable else { return }
        let row = albumTable.selectedRow
        let id = row >= 0 && row < shownAlbums.count ? shownAlbums[row].id : nil
        guard id != model.selectedID else { return }
        model.selectedID = id
        showSelected()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        guard tableView === trackTable, model.canRemap, let fileID = rows[row].fileID else {
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
        guard tableView === trackTable, model.canRemap, row < rows.count else { return [] }
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
        guard model.canRemap, row < rows.count else { return false }
        model.assign(fileID, to: rows[row].track)
        return true
    }

    // MARK: - Actions

    @objc private func scopeChosen() {
        model.scope = TaggerModel.Scope.allCases[scopePopUp.indexOfSelectedItem]
    }

    @objc private func tabChosen() {
        model.tab = MatchTier.allCases[tabs.selectedSegment]
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
            fillSortArtist: sortArtistBox.state == .on)
        model.setChoices(choices)
        choicesChosen(choices)
    }

    @objc private func showMapping() {
        guard let window, sheet == nil else { return }
        let mapping = MappingSheet(
            draft: MappingDraft(mapping: model.mapping, saved: model.savedMappings))
        present(mapping, over: window) { [weak self] in
            guard let draft = mapping.result else { return }
            self?.mappingChosen(draft.mapping, draft.saved)
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
                title: albumTitle(album.album))
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
                return alert("The release couldn't be read", ["\(error)"], over: sheetWindow)
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
                set: set, excluded: album.excluded, title: albumTitle(album.album),
                releaseID: releaseID)
            present(changes, over: window) { [self] in
                guard let answer = changes.result else { return }
                model.setExcluded(answer.excluded, for: album.id)
                if answer.apply { apply([album.id]) }
            }
        }
    }

    @objc private func toggleRejected() {
        guard let album = model.selected else { return }
        Task { await model.setRejected(!album.isRejected, album.id) }
    }

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
            let (message, detail) = TaggerModel.confirmation(plan)
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
        let shown = 8
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText =
            details.prefix(shown).joined(separator: "\n")
            + (details.count > shown ? "\n(\(details.count - shown) more not shown)" : "")
        alert.beginSheetModal(for: window)
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
