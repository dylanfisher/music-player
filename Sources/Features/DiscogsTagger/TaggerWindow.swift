import AppKit
import Discogs
import DisplayText
import Library
import Log
import Settings
import TagWriter

/// The tagger's window (51.11): the toolbar's source, scope, Analyze and Field Mapping…; a tab
/// per tier with its count, each an album list; the selected album's release beside its
/// tracklist, file against track; and the buttons that review it and apply a tier. Without a
/// catalog it says so and offers the import, and Analyze stays off.
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
    let importButton = NSButton(title: "Import Discogs Dump…", target: nil, action: nil)
    let progress = NSProgressIndicator()
    let statusLabel = NSTextField(labelWithString: "")
    let catalogLabel = NSTextField(wrappingLabelWithString: "")
    let catalogBox = NSStackView()
    let tabs = NSSegmentedControl()
    let albumTable = NSTableView()
    let trackTable = NSTableView()
    let releaseTitle = NSTextField(labelWithString: "")
    let releaseLine = NSTextField(labelWithString: "")
    let otherReleasesButton = NSButton(title: "Other Releases…", target: nil, action: nil)
    let changesButton = NSButton(title: "View Changes…", target: nil, action: nil)
    let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    let applyButton = NSButton(title: "", target: nil, action: nil)

    /// Writes the confirmed edits.
    var write: ([(path: String, edit: TagEdit)]) -> Void = { _ in }
    var mappingChosen: (DiscogsMapping, [NamedDiscogsMapping]) -> Void = { _, _ in }
    var dumpsFolder: () -> URL? = { nil }
    var dumpsFolderChosen: (URL) -> Void = { _ in }

    /// The albums of the tab shown, in list order.
    private(set) var shownAlbums: [TaggerModel.Album] = []
    /// The selected album's tracklists side by side.
    private(set) var rows: [TrackComparison] = []
    /// An open sheet's controller, held while it shows.
    private var sheet: NSWindowController?

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
        model.write = { [weak self] files in self?.write(files) }
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
            (otherReleasesButton, #selector(showOtherReleases)),
            (changesButton, #selector(showChanges)), (rejectButton, #selector(toggleRejected)),
            (applyButton, #selector(applyAll)),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
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

        let bar = NSStackView(views: [
            label("Source:"), sourcePopUp, label("Scope:"), scopePopUp, analyzeButton, progress,
            statusLabel, NSView(), importButton, mappingButton,
        ])
        bar.spacing = 8

        let catalogImport = NSButton(
            title: "Import Discogs Dump…", target: self, action: #selector(chooseDumps))
        catalogImport.bezelStyle = .rounded
        catalogBox.setViews([catalogLabel, catalogImport], in: .leading)
        catalogBox.spacing = 12
        catalogLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        let buttons = NSStackView(views: [otherReleasesButton, changesButton, rejectButton])
        buttons.spacing = 8
        let detail = NSStackView(views: [
            releaseTitle, releaseLine, tracks, buttons,
        ])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6
        detail.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        for view in detail.arrangedSubviews where view is NSScrollView {
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

        let bottom = NSStackView(views: [NSView(), applyButton])
        let page = NSStackView(views: [bar, catalogBox, tabs, split, bottom])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for view in [bar, catalogBox, split, bottom] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -28).isActive = true
        }
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = page
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    // MARK: - Showing the model

    /// Shows the model as it is now: the catalog, the work running, the tabs, the albums and
    /// the selected album.
    func refresh() {
        switch model.catalog {
        case .checking, .ready:
            catalogBox.isHidden = true
        case .missing:
            catalogBox.isHidden = false
            catalogLabel.stringValue =
                "There's no Discogs catalog on this Mac, so there's nothing to match with."
                + " Import Discogs Dump… builds one from the dumps folder."
        case .unusable(let why):
            catalogBox.isHidden = false
            catalogLabel.stringValue = "The Discogs catalog can't be used: \(why)."
        }
        sourcePopUp.selectItem(at: TaggerModel.Source.allCases.firstIndex(of: model.source)!)
        scopePopUp.selectItem(at: TaggerModel.Scope.allCases.firstIndex(of: model.scope)!)
        scopePopUp.isEnabled = !model.isBusy
        importButton.isEnabled = !model.isBusy
        mappingButton.isEnabled = sheet == nil
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
            stoppable = true
            progress.isHidden = false
            progress.doubleValue = step?.fraction ?? 0
            statusLabel.stringValue = step?.text ?? "Starting the import"
        }
        analyzeButton.title = stoppable ? "Stop" : "Analyze"
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
        rows = album.map { $0.match.comparison(of: $0.album) } ?? []
        trackTable.reloadData()
        let reviewing = album != nil && !model.isBusy
        otherReleasesButton.isEnabled = reviewing
        changesButton.isEnabled = reviewing && summary != nil && album?.isRejected == false
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
        if tableView === albumTable, shownAlbums[row].isRejected || shownAlbums[row].applied {
            cell.textColor = .secondaryLabelColor
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

    @objc private func chooseDumps() {
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
            model.importDump(from: url)
        }
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
            present(releases, over: window) { [self] in
                guard let id = releases.result, id != album.match.releaseID else { return }
                Task { await model.choose(id, for: album.id) }
            }
        }
    }

    @objc private func showChanges() {
        guard let window, let album = model.selected, sheet == nil else { return }
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
                set: set, excluded: album.excluded, title: albumTitle(album.album))
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
        _ controller: NSWindowController & TaggerSheet, over window: NSWindow,
        ended: @escaping () -> Void
    ) {
        guard let sheetWindow = controller.window else { return }
        sheet = controller
        refresh()
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.sheet = nil
            ended()
            self?.refresh()
        }
    }

    private func alert(_ message: String, _ details: [String]) {
        guard let window else { return }
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
protocol TaggerSheet: AnyObject {}

extension NSWindowController {
    /// Ends the sheet this controller's window is.
    func endSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
