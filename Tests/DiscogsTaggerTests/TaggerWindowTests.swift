import AppKit
import DisplayText
import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Fixtures
@testable import Metadata
@testable import Settings
@testable import TagWriter

private let stockholm = ["Östermalm", "Gamla Stan", "Kungsholmen"]

/// Two albums: Stockholm Exact with its files on the tracks, Second Likely with one file short
/// of the release.
@MainActor
private func analyzed() async -> TaggerModel {
    let albums = [
        album(1, "Stockholm", titles: stockholm),
        album(2, "Second", artist: "Abba", titles: ["Östermalm", "Other"]),
    ]
    let tagger = await model(
        Seen(), albums: albums,
        matches: { album, _ in
            album.id == 1
                ? match(
                    album, release(10, "Stockholm", titles: stockholm), tier: .exact,
                    candidates: [11])
                : match(album, release(20, "Second", titles: stockholm), tier: .likely)
        })
    tagger.analyze()
    await tagger.finished()
    return tagger
}

/// Writes a picture of `window` for review, under .build.
@MainActor
private func snapshot(_ window: NSWindow, _ name: String) throws {
    let content = try #require(window.contentView)
    content.layoutSubtreeIfNeeded()
    let image = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: image)
    let out = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/snapshots/\(name).png", isDirectory: false)
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #require(image.representation(using: .png, properties: [:])).write(to: out)
}

@MainActor
@Test func withoutACatalogTheWindowSaysSoAndOffersTheImport() async throws {
    let tagger = await model(
        Seen(), albums: [], matches: { album, _ in match(album, nil, tier: .noCandidate) },
        catalog: .missing)
    let window = TaggerWindow(model: tagger)
    #expect(!window.catalogBox.isHidden)
    #expect(window.catalogLabel.stringValue.contains("no Discogs catalog on this Mac"))
    #expect(window.catalogLabel.stringValue.contains("Import Discogs Dump…"))
    #expect(!window.analyzeButton.isEnabled)
    #expect(window.importButton.isEnabled)
    #expect(window.importButton.title == "Import Discogs Dump…")
    #expect(window.importButton.superview === window.catalogLabel.superview, "beside the line")
    #expect(window.revealButton.isHidden)
    #expect(window.sourcePopUp.itemArray.map { $0.isEnabled } == [true, true, true])
    window.window?.close()
}

@MainActor
@Test func theTabsCountTheTiersAndTheSelectedAlbumShowsItsTracklists() async throws {
    let tagger = await analyzed()
    let controller = TaggerWindow(model: tagger)
    let window = try #require(controller.window)
    #expect(!controller.catalogBox.isHidden, "the catalog in place")
    #expect(controller.tabs.label(forSegment: 0) == "Exact (1)")
    #expect(controller.tabs.label(forSegment: 1) == "Likely (1)")
    #expect(controller.applyButton.title == "Apply to All in Exact…")
    #expect(controller.applyButton.isEnabled)
    #expect(controller.shownAlbums.map(\.id) == [1])
    #expect(controller.releaseTitle.stringValue == "Persuader – Stockholm")
    #expect(controller.releaseLine.stringValue == "Svek · SK 10 · Sweden · 2000 · CD · Release 10")
    #expect(controller.rows.map(\.state) == [.matched, .matched, .matched])
    #expect(controller.text(controller.releaseTable, .state, 0) == "✓ Same")
    #expect(!controller.drop(100, onRow: 2), "an Exact album's rows stay")
    try snapshot(window, "discogs-tagger")

    tagger.tab = .likely
    tagger.selectedID = 2
    controller.refresh()
    #expect(controller.rows.map(\.state) == [.matched, .different, .missing])
    #expect(controller.drop(201, onRow: 2))
    #expect(controller.rows.map(\.fileID) == [200, nil, 201])
    #expect(controller.rows.map(\.state) == [.matched, .missing, .different])
    window.close()
}

/// The files and the release's tracks are two tables of the same rows, each under its heading,
/// the match's mark spelled out, scrolled and selected together.
@MainActor
@Test func theFilesAndTheReleaseAreTwoTablesOfTheSameRows() async throws {
    let tagger = await analyzed()
    tagger.tab = .likely
    tagger.selectedID = 2
    let controller = TaggerWindow(model: tagger)
    let window = try #require(controller.window)
    defer { window.close() }
    let (files, tracks) = (controller.fileTable, controller.releaseTable)
    #expect(
        files.tableColumns.map(\.identifier.rawValue)
            == ["include", "number", "fileTitle", "fileTime"])
    #expect(
        tracks.tableColumns.map(\.identifier.rawValue)
            == ["position", "releaseTitle", "releaseTime", "state"])
    #expect(files.tableColumns[2].title == tracks.tableColumns[1].title, "both Title")
    let labels = allViews(window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(labels.contains(TaggerText.filesHeading))
    #expect(labels.contains(TaggerText.releaseHeading))
    #expect(files.numberOfRows == 3 && tracks.numberOfRows == 3)
    #expect(files.rowHeight == tracks.rowHeight)
    #expect(
        (0..<3).map { controller.text(tracks, .state, $0) } == [
            "✓ Same", "≠ Differs", "– No file",
        ])
    #expect(controller.text(files, .fileTitle, 2) == "", "the track without a file")
    #expect(controller.text(tracks, .releaseTitle, 2) == "Kungsholmen")
    #expect(controller.drop(201, onRow: 2))
    #expect(controller.text(tracks, .state, 1) == "– No file")

    files.selectRowIndexes([1], byExtendingSelection: false)
    #expect(tracks.selectedRowIndexes == [1])
    tracks.selectRowIndexes([2], byExtendingSelection: false)
    #expect(files.selectedRowIndexes == [2])

    // Unticking a file leaves it out: listed last, greyed, on no track.
    let box = try #require(
        controller.tableView(files, viewFor: files.tableColumns[0], row: 0) as? NSButton)
    #expect(box.state == .on && box.isEnabled)
    controller.setIncluded(false, row: 0)
    try await eventually { controller.leftOut == [200] && tagger.rematchingID == nil }
    #expect(controller.rows.last?.fileID == 200)
    #expect(controller.text(tracks, .state, controller.rows.count - 1) == "Left out")
    let unticked = try #require(
        controller.tableView(
            files, viewFor: files.tableColumns[0], row: controller.rows.count - 1) as? NSButton)
    #expect(unticked.state == .off)
    #expect(!controller.drop(200, onRow: 0), "a file left out can't be dragged")
    try snapshot(window, "discogs-tagger-tracklists")

    let titles = (1...60).map { "Track \($0)" }
    let long = await model(
        Seen(), albums: [album(5, "Long", titles: titles)],
        matches: { album, _ in match(album, release(50, "Long", titles: titles), tier: .exact) })
    long.analyze()
    await long.finished()
    let tall = TaggerWindow(model: long)
    defer { tall.window?.close() }
    tall.window?.setContentSize(NSSize(width: 1000, height: 480))
    tall.window?.contentView?.layoutSubtreeIfNeeded()
    let moved = try #require(tall.releaseTable.enclosingScrollView?.contentView)
    moved.scroll(to: NSPoint(x: 0, y: 120))
    #expect(moved.bounds.origin.y == 120)
    #expect(tall.fileTable.enclosingScrollView?.contentView.bounds.origin.y == 120)
    tall.fileTable.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 40))
    #expect(moved.bounds.origin.y == 40, "and back")
}

/// `view` and every view under it.
@MainActor
private func allViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
}

@MainActor
@Test func viewChangesMergesAChangeTheSameInSeveralFilesAndTicksItInEach() throws {
    let change = { (file: Int64, field: DiscogsField, tag: String, new: String) in
        TagChange(
            id: TagChange.ID(fileID: file, tag: .custom(tag)), field: field, current: nil,
            new: new)
    }
    let files = { (file: Int64, position: String) in
        FileChanges(
            fileID: file, path: "/m/\(file).flac",
            changes: [
                change(file, .releaseID, "DISCOGS_RELEASE_ID", "10"),
                change(file, .position, "TRACK_NUMBER_TEXT", position),
            ],
            unwritable: nil, tags: TrackTags())
    }
    let set = AlbumChangeSet(files: [
        files(1, "1-1"),
        FileChanges(
            fileID: 2, path: "/m/2.dsf", changes: [], unwritable: "Tags in DSD files can't be",
            tags: TrackTags()),
        files(3, "1-2"),
    ])
    let sheet = ChangesSheet(
        set: set, excluded: [], title: "Persuader – Stockholm", releaseID: 10)
    #expect(sheet.releaseID == 10)
    #expect(sheet.rows.count == 4, "the release id once, a position per file, the DSD file")
    #expect(sheet.text(.fileName, 0) == "All 2 files")
    #expect(sheet.text(.written, 0) == "10")
    #expect(sheet.text(.fileName, 1) == "1.flac")
    #expect(sheet.text(.written, 2) == "1-2")
    #expect(sheet.text(.fileName, 3) == "2.dsf")
    #expect(sheet.summary.stringValue == "4 of 4 changes in 2 files")
    sheet.toggle(0)
    #expect(
        sheet.excluded == [
            TagChange.ID(fileID: 1, tag: .custom("DISCOGS_RELEASE_ID")),
            TagChange.ID(fileID: 3, tag: .custom("DISCOGS_RELEASE_ID")),
        ])
    #expect(sheet.summary.stringValue == "2 of 4 changes in 2 files")
    sheet.toggle(0)
    #expect(sheet.excluded.isEmpty)
    sheet.toggle(3)
    #expect(sheet.excluded.isEmpty, "a file nothing is written to has no box")
}

@MainActor
@Test func otherReleasesFilterByEachColumn() {
    let summary = { (id: Int, country: String, format: String) in
        ReleaseSummary(
            id: id, artist: "Persuader", title: "Stockholm", label: "Svek",
            catalogNumber: "SK \(id)", country: country, year: "2000", format: format,
            trackCount: 3)
    }
    let sheet = ReleasesSheet(
        candidates: [
            (summary(1, "Sweden", "CD (Album)"), nil), (summary(2, "UK", "Vinyl (LP)"), 0.9),
            (summary(3, "Sweden", "Vinyl (LP)"), 0.8),
        ],
        chosen: 1, title: "Stockholm")
    sheet.filter([.country: "swed"])
    #expect(sheet.shown.map(\.summary.id) == [1, 3])
    sheet.filter([.country: "swed", .format: "vinyl"])
    #expect(sheet.shown.map(\.summary.id) == [3])
    sheet.filter([.label: "SK 2"])
    #expect(sheet.shown.map(\.summary.id) == [2])
}

/// Other Releases sorts by any column's header, numbers as numbers, keeping the sort through a
/// filter, and shows each release's track count (51.37).
@MainActor
@Test func otherReleasesSortByEachColumnAndCountTracks() throws {
    let summary = { (id: Int, artist: String, year: String, tracks: Int) in
        ReleaseSummary(
            id: id, artist: artist, title: "Title \(4 - id)", label: "Label \(id % 3)",
            catalogNumber: "SK \(10 - id)", country: id == 2 ? "UK" : "Sweden", year: year,
            format: "Format \(id)", trackCount: tracks)
    }
    let sheet = ReleasesSheet(
        candidates: [
            (summary(1, "Persuader", "2000", 12), nil), (summary(2, "abba", "1999", 9), 0.9),
            (summary(3, "Cobra", "", 10), 0.95),
        ],
        chosen: 1, title: "Stockholm")
    #expect(sheet.table.tableColumns.allSatisfy { $0.sortDescriptorPrototype != nil })
    #expect(sheet.table.tableColumns.last?.title == "Tracks")
    #expect(sheet.text(0, .tracks) == "12")
    let order = { (column: TaggerColumn, ascending: Bool) in
        sheet.sort(by: column, ascending: ascending)
        return sheet.shown.map(\.summary.id)
    }
    #expect(order(.tracks, true) == [2, 3, 1], "9 before 10 before 12")
    #expect(order(.tracks, false) == [1, 3, 2])
    #expect(order(.score, true) == [2, 3, 1], "the chosen release's fit above any score")
    #expect(order(.year, true) == [3, 2, 1], "no year first")
    #expect(order(.artist, true) == [2, 3, 1], "ignoring case")
    #expect(order(.title, true) == [3, 2, 1])
    #expect(order(.label, true) == [3, 1, 2])
    #expect(order(.catalogNumber, true) == [3, 2, 1])
    #expect(order(.country, false) == [2, 1, 3], "equal values keep the found order")
    #expect(order(.format, false) == [3, 2, 1])
    sheet.filter([.country: "swe"])
    #expect(sheet.shown.map(\.summary.id) == [3, 1], "still by format, descending")
}

/// View Release shows the release from the catalog, headings included, and Open on Discogs
/// opens its page from the one URL builder.
@MainActor
@Test func viewReleaseShowsTheTracklistAndItsDiscogsPage() async throws {
    let tagger = await model(
        Seen(), albums: [], matches: { album, _ in match(album, nil, tier: .noCandidate) })
    let detail = try #require(try await tagger.release(42))
    let sheet = ViewReleaseSheet(release: detail)
    #expect(sheet.heading.stringValue == "Persuader – Release 42")
    #expect(sheet.line.stringValue == "Svek · SK 42 · CD · Sweden · 2000")
    #expect(sheet.numberOfRows(in: sheet.table) == 3)
    #expect(
        (0..<3).map { row in
            [TaggerColumn.position, .title, .releaseTime].map { sheet.text($0, row) }
        } == [["", "Side A", ""], ["A1", "Östermalm", "4:45"], ["A2", "Gamla Stan", "6:10"]])
    #expect(discogsPage(detail.summary.id).absoluteString == releaseURL(42))
    #expect(releaseURL(42) == "https://www.discogs.com/release/42")
    try snapshot(try #require(sheet.window), "discogs-view-release")
}

@MainActor
@Test func theFieldMappingSheetListsEveryFieldAndEditsTheDraft() throws {
    let sheet = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.oneToOne.mapping, saved: []), artwork: .off,
        hasToken: true)
    #expect(sheet.numberOfRows(in: sheet.table) == DiscogsField.allCases.count)
    #expect(MappingSheet.fields.first == .releaseID)
    #expect(MappingSheet.fields.last == .involvedPeople)
    #expect(sheet.presets.titleOfSelectedItem == DiscogsPreset.oneToOne.name)
    try snapshot(try #require(sheet.window), "discogs-mapping-sheet")
    let row = try #require(MappingSheet.fields.firstIndex(of: .styles))
    sheet.set("mood, STYLE", in: .targets, row: row)
    #expect(sheet.draft.mapping[.styles].targets == [.field(.mood), .key("STYLE")])
    #expect(sheet.presets.titleOfSelectedItem == "Edited")
    #expect(sheet.okButton.isEnabled)
    sheet.set("", in: .join, row: row)
    #expect(!sheet.okButton.isEnabled, "a list needs a join")
    #expect(sheet.problemLabel.stringValue == "styles is a list, so it needs a join")
}

@MainActor
@Test func removeTakesTheChosenSavedMappingOutOfStartFrom() throws {
    var mine = DiscogsPreset.minimal.mapping
    mine[.label].mode = .off
    let sheet = MappingSheet(
        draft: MappingDraft(
            mapping: DiscogsPreset.oneToOne.mapping,
            saved: [NamedDiscogsMapping(name: "Mine", mapping: mine)]),
        artwork: .off, hasToken: true)
    #expect(!sheet.removeButton.isEnabled, "a preset is shown")
    sheet.presets.selectItem(withTitle: "Mine")
    sheet.presets.sendAction(sheet.presets.action, to: sheet.presets.target)
    #expect(sheet.removeButton.isEnabled)
    sheet.removeSaved()
    #expect(!sheet.presets.itemTitles.contains("Mine"))
    #expect(sheet.draft.saved.isEmpty)
    #expect(sheet.presets.titleOfSelectedItem == "Edited")
    #expect(!sheet.removeButton.isEnabled)
    #expect(sheet.problemLabel.stringValue == "Removed “Mine”; OK keeps the change")
}

/// The folders and flags each import was started with.
private final class Imports: @unchecked Sendable {
    // `started` is guarded by `lock`.
    private let lock = NSLock()
    private var started: [(URL, Bool)] = []

    func start(_ folder: URL, _ startingOver: Bool) {
        lock.withLock { started.append((folder, startingOver)) }
    }

    var flags: [Bool] { lock.withLock { started.map(\.1) } }
    var folders: [URL] { lock.withLock { started.map(\.0) } }
}

@MainActor
@Test func anUnfinishedImportOffersResumeImportAndStartOver() async throws {
    let imports = Imports()
    let tagger = await model(
        Seen(), albums: [], matches: { album, _ in match(album, nil, tier: .noCandidate) },
        unfinished: UnfinishedImport(dumpDate: "20261101", fraction: 0.76),
        importing: { folder, startingOver, _ in
            imports.start(folder, startingOver)
            throw CatalogImportError.stopped
        })
    let controller = TaggerWindow(model: tagger)
    let dumps = URL(fileURLWithPath: "/Volumes/music/discogs", isDirectory: true)
    controller.dumpsFolder = { dumps }
    #expect(!controller.resumeBox.isHidden)
    try snapshot(try #require(controller.window), "discogs-tagger-resume")
    #expect(
        controller.resumeLabel.stringValue.hasPrefix(
            "The import of the 20261101 Discogs dump stopped at 76%."))
    click(controller.resumeButton)
    #expect(controller.resumeBox.isHidden)
    await tagger.finished()
    try await eventually { !tagger.isBusy && !controller.resumeBox.isHidden }
    click(controller.startOverButton)
    await tagger.finished()
    try await eventually { !tagger.isBusy }
    #expect(imports.flags == [false, true])
    #expect(imports.folders == [dumps, dumps])
    controller.window?.close()
}

@MainActor
@Test func theChoicesBesideFieldMappingShowAndSaveTheModels() async throws {
    let tagger = await analyzed()
    let window = TaggerWindow(model: tagger)
    var saved: [TaggerChoices] = []
    window.choicesChosen = { saved.append($0) }
    #expect(window.keepBox.state == .off)
    #expect(window.skipVideoBox.state == .on)
    #expect(window.sortArtistBox.state == .off)
    #expect(window.mappingButton.superview === window.keepBox.superview, "beside Field Mapping…")

    window.keepBox.performClick(nil)
    #expect(tagger.choices.keepExistingValues)
    #expect(
        saved == [TaggerChoices(keepExistingValues: true, skipVideo: true, fillSortArtist: false)])
    window.sortArtistBox.performClick(nil)
    #expect(saved.last?.fillSortArtist == true)
    window.skipVideoBox.performClick(nil)
    #expect(saved.last?.skipVideo == false)
    #expect(!window.skipVideoBox.isEnabled, "off while the rescore runs")
    await tagger.finished()
    #expect(window.skipVideoBox.isEnabled)
    #expect(window.skipVideoBox.state == .off)
    try snapshot(try #require(window.window), "discogs-tagger-choices")
}

@MainActor
@Test func saveAsChoosesTheNewNameAndAsksBeforeReplacingOne() throws {
    let mine = NamedDiscogsMapping(name: "Mine", mapping: DiscogsPreset.minimal.mapping)
    let sheet = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.oneToOne.mapping, saved: [mine]),
        artwork: .off, hasToken: true)
    var asked: [String] = []
    var answer = false
    sheet.confirmReplace = { name, reply in
        asked.append(name)
        reply(answer)
    }
    sheet.nameField.stringValue = "Copy"
    sheet.saveAs()
    #expect(asked.isEmpty, "a new name doesn't ask")
    #expect(sheet.presets.titleOfSelectedItem == "Copy", "not One to one, which it equals")
    #expect(sheet.problemLabel.stringValue == "Saved as “Copy”")

    sheet.nameField.stringValue = " Mine "
    sheet.saveAs()
    #expect(asked == ["Mine"])
    #expect(sheet.draft.saved.first { $0.name == "Mine" }?.mapping == mine.mapping, "kept")
    #expect(sheet.presets.titleOfSelectedItem == "Copy")
    answer = true
    sheet.saveAs()
    #expect(asked == ["Mine", "Mine"])
    #expect(sheet.draft.saved.map(\.name) == ["Copy", "Mine"])
    #expect(sheet.draft.saved.last?.mapping == DiscogsPreset.oneToOne.mapping, "replaced")
    #expect(sheet.presets.titleOfSelectedItem == "Mine")
    #expect(sheet.problemLabel.stringValue == "Saved as “Mine”")

    sheet.set("STYLE", in: .targets, row: try #require(MappingSheet.fields.firstIndex(of: .styles)))
    #expect(sheet.presets.titleOfSelectedItem == "Edited")
    #expect(sheet.problemLabel.stringValue.isEmpty, "the note goes with the next edit")
}

@MainActor
@Test func aMappingExportedImportedAndPastedBackIsTheOneExported() throws {
    var mapping = DiscogsPreset.yate.mapping
    mapping[.genres].format.template = "{genre} - {styles}"
    let sheet = MappingSheet(
        draft: MappingDraft(mapping: mapping, saved: []), artwork: .off, hasToken: true)
    var refusals: [String] = []
    sheet.refused = { message, _ in refusals.append(message) }
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("mapping.json", isDirectory: false)
    sheet.export(to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text == AppSettings().discogsMapping.text(mapping), "the config file's shape")

    let other = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.oneToOne.mapping, saved: []), artwork: .off,
        hasToken: true)
    other.refused = { message, _ in refusals.append(message) }
    other.importFile(at: file)
    #expect(other.draft.mapping == mapping)
    #expect(other.presets.titleOfSelectedItem == "Edited")
    #expect(
        other.problemLabel.stringValue == "Imported “mapping.json”, not saved; Save As keeps it")

    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let pasted = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.minimal.mapping, saved: []), artwork: .off,
        hasToken: true)
    pasted.pasteboard = pasteboard
    pasted.refused = { message, _ in refusals.append(message) }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasted.paste()
    #expect(pasted.draft.mapping == mapping)
    #expect(refusals.isEmpty)

    pasteboard.clearContents()
    pasteboard.setString("{\"styles\": {}}", forType: .string)
    pasted.paste()
    #expect(pasted.draft.mapping == mapping, "a bad paste changes nothing")
    #expect(refusals == ["That isn't a field mapping the config file takes"])
    other.importFile(at: folder.appendingPathComponent("missing.json", isDirectory: false))
    #expect(other.draft.mapping == mapping)
    #expect(refusals.last == "The file couldn't be read")
}

@MainActor
@Test func withACatalogTheWindowSaysWhatItIsAndOffersAReimport() async throws {
    let tagger = await model(
        Seen(), albums: [], matches: { album, _ in match(album, nil, tier: .noCandidate) })
    guard case .ready(let status) = readyCatalog else {
        Issue.record("a ready catalog")
        return
    }
    let controller = TaggerWindow(model: tagger)
    try snapshot(try #require(controller.window), "discogs-tagger-catalog")
    #expect(!controller.catalogBox.isHidden)
    #expect(
        controller.catalogLabel.stringValue
            == "Catalog from the 2026-11-01 dump · \(fileSizeText(status.sizeBytes))")
    let tip = try #require(controller.catalogLabel.toolTip)
    #expect(tip.hasPrefix("/Volumes/Scratch/discogs-catalog.sqlite\nImported "))
    #expect(
        tip.hasSuffix(
            DateFormatter.localizedString(
                from: status.importedAt, dateStyle: .medium, timeStyle: .short)))
    #expect(!controller.revealButton.isHidden)
    #expect(controller.revealButton.superview === controller.catalogLabel.superview)
    #expect(controller.importButton.title == "Reimport Discogs Dump…")
    #expect(controller.importButton.toolTip?.isEmpty == false)
    #expect(controller.mappingButton.toolTip?.isEmpty == false)
    controller.window?.close()
}

/// How many times the catalog was checked, from any thread.
private final class Checks: @unchecked Sendable {
    // `count` is guarded by `lock`.
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

@MainActor
@Test func theImportButtonKeepsItsTitleWhileTheCatalogIsChecked() async throws {
    let gate = Gate()
    let checks = Checks()
    let tagger = TaggerModel(
        effects: .init(
            albums: { [] }, reviews: { [:] }, review: { _, _ in },
            match: { _, _, _, _, _ in [] }, choose: { _, previous, _, _ in previous },
            summaries: { _ in [] }, release: { _ in nil },
            read: { _, _ in ([], []) },
            checkCatalog: {
                if checks.next() > 1 { gate.wait() }
                return readyCatalog
            },
            unfinishedImport: { nil },
            importCatalog: { _, _, _ in throw CatalogImportError.stopped }),
        mapping: DiscogsPreset.minimal.mapping, savedMappings: [], choices: defaultChoices)
    await tagger.checkCatalog()
    let controller = TaggerWindow(model: tagger)
    #expect(controller.importButton.title == "Reimport Discogs Dump…")
    let checking = Task { await tagger.checkCatalog() }
    try await eventually { tagger.catalog == .checking }
    #expect(controller.importButton.title == "Reimport Discogs Dump…")
    gate.open()
    await checking.value
    #expect(controller.importButton.title == "Reimport Discogs Dump…")
    controller.window?.close()
}

/// `view`'s frame in its window's coordinates.
@MainActor
private func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

/// At the window's minimum width each header row is one line: every control inside the
/// window, none over another, and only the lines that truncate narrower than they'd be.
@MainActor
@Test func theHeaderFitsTheMinimumWidthOnOneLinePerRow() async throws {
    for catalog in [readyCatalog, .missing] {
        let tagger = await model(
            Seen(), albums: [], matches: { album, _ in match(album, nil, tier: .noCandidate) },
            catalog: catalog, unfinished: UnfinishedImport(dumpDate: "20261101", fraction: 0.5))
        let controller = TaggerWindow(model: tagger)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: window.minSize.width, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let content = frame(try #require(window.contentView))
        let truncating = [controller.catalogLabel, controller.resumeLabel, controller.statusLabel]
        for row in controller.headerRows where !row.isHidden {
            let controls = row.arrangedSubviews.filter {
                !$0.isHidden && type(of: $0) != NSView.self
            }
            .sorted { frame($0).minX < frame($1).minX }
            for (control, next) in zip(controls, controls.dropFirst()) {
                #expect(frame(control).maxX <= frame(next).minX, "\(control) beside \(next)")
            }
            for control in controls {
                let shown = frame(control)
                #expect(content.contains(shown), "\(control) in the window")
                #expect(abs(shown.midY - frame(row).midY) <= 2, "\(control) on its row's line")
                if !truncating.contains(where: { $0 === control }) {
                    #expect(shown.width >= control.fittingSize.width - 1, "\(control) whole")
                }
            }
        }
        try snapshot(window, "discogs-tagger-narrow-\(catalog == .missing ? "missing" : "ready")")
        window.close()
    }
}

/// Opened with tracks selected in the library, the tagger is scoped to their albums and, with a
/// catalog, analyzes them; without a selection it opens as before, and without a catalog it
/// only scopes.
@MainActor
@Test func openingWithASelectionScopesToItAndAnalyzes() async throws {
    for (selection, catalog, analyzes) in [
        ([Int64(100)], readyCatalog, true), ([], readyCatalog, false),
        ([100], TaggerModel.CatalogState.missing, false),
    ] {
        let seen = Seen()
        let tagger = DiscogsTagger(
            model: await model(
                seen, albums: [album(1, "Stockholm", titles: stockholm)],
                matches: { album, _ in
                    match(album, release(10, "Stockholm", titles: stockholm), tier: .exact)
                },
                catalog: catalog))
        tagger.selectedTracks = { selection }
        tagger.show()
        #expect(tagger.model.scope == (selection.isEmpty ? .library : .selection))
        if analyzes {
            try await eventually { seen.matched.count == 1 }
        } else {
            try await eventually { tagger.model.catalog != .checking }
            // Long enough for an analyze the check would start to show.
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        await tagger.model.finished()
        #expect(seen.matched.count == (analyzes ? 1 : 0), "\(selection) \(catalog)")
        #expect(tagger.model.albums.map(\.id) == (analyzes ? [1] : []))

        // Shown again with a selection, an open window does the same.
        tagger.model.scope = .library
        tagger.selectedTracks = { [100] }
        tagger.show()
        #expect(tagger.model.scope == .selection)
        tagger.window?.close()
    }
}

/// A Likely album says why it isn't Exact under its release's title and in its row's tooltip.
@MainActor
@Test func aLikelyAlbumSaysWhyUnderItsTitleAndInItsTooltip() async throws {
    let likely = album(2, "Second", titles: ["Östermalm", "Other"])
    var matched = match(likely, release(20, "Second", titles: stockholm), tier: .likely)
    matched.reasons = [
        .countDiffers(files: 2, tracks: 3), .tracksWithoutFile(1),
        .durationsDiffer(3, overSeconds: 8, orFraction: 0.05),
    ]
    let reasoned = matched
    let tagger = await model(Seen(), albums: [likely], matches: { _, _ in reasoned })
    tagger.analyze()
    await tagger.finished()
    tagger.tab = .likely
    tagger.selectedID = 2
    let controller = TaggerWindow(model: tagger)
    let words = [
        "2 files, the release has 3 tracks", "1 track of the release has no file",
        "3 file lengths are off by more than 8 s or 5%",
    ]
    #expect(controller.reasonsLine.stringValue == words.joined(separator: " · "))
    let cell = controller.tableView(
        controller.albumTable, viewFor: controller.albumTable.tableColumns[0], row: 0)
    #expect(cell?.toolTip == words.joined(separator: "\n"))
    #expect(NotExactReason.filesWithoutTrack(2).text == "2 files have no track on the release")
    #expect(NotExactReason.foundByTitleOnly.text == "found by title only")

    tagger.tab = .exact
    tagger.selectedID = nil
    controller.refresh()
    #expect(controller.reasonsLine.stringValue.isEmpty)
    controller.window?.close()
}

/// The tracklists and the album list take the height the header and the buttons leave: their
/// bottoms sit on the button rows, and they grow with the window. Checked on the first open,
/// after an import, after reopening and after a resize, since the owner saw them short once.
@MainActor
@Test func theTablesTakeTheHeightLeftInEveryCase() async throws {
    let made = await model(
        Seen(), albums: [album(1, "Stockholm", titles: stockholm)],
        matches: { album, _ in
            match(album, release(10, "Stockholm", titles: stockholm), tier: .exact)
        },
        unfinished: UnfinishedImport(dumpDate: "20261101", fraction: 0.5),
        importing: { _, _, _ in
            CatalogImportSummary(
                dumpDate: "20261101", records: [:], compressedBytes: 0, catalogBytes: 0,
                seconds: 1, resumedBytes: 0)
        })
    let tagger = DiscogsTagger(model: made)
    tagger.dumpsFolder = { URL(fileURLWithPath: "/Volumes/music/discogs", isDirectory: true) }
    tagger.show()
    let controller = try #require(tagger.window?.windowController as? TaggerWindow)
    let window = try #require(tagger.window)
    window.setContentSize(NSSize(width: 1060, height: 700))

    func expectFilled(_ when: String) {
        let tracks = frame(controller.releaseTable.enclosingScrollView!)
        let albums = frame(controller.albumTable.enclosingScrollView!)
        #expect(abs(tracks.minY - frame(controller.reviewButtons).maxY) <= 12, "\(when)")
        #expect(abs(albums.minY - frame(controller.bottom).maxY) <= 12, "\(when)")
        #expect(tracks.height > 200 && albums.height > 300, "\(when): \(tracks) \(albums)")
        var views = [window.contentView!]
        while let view = views.popLast() {
            #expect(!view.hasAmbiguousLayout, "\(when): \(view) \(view.frame)")
            views += view.subviews
        }
    }
    window.contentView?.layoutSubtreeIfNeeded()
    expectFilled("first open")
    await tagger.model.finished()
    try await eventually { tagger.model.catalog != .checking }
    expectFilled("once the catalog is checked")

    click(controller.resumeButton)
    await tagger.model.finished()
    try await eventually { tagger.model.catalog != .checking && !tagger.model.isBusy }
    expectFilled("after an import")

    window.close()
    tagger.show()
    window.contentView?.layoutSubtreeIfNeeded()
    expectFilled("after reopening")

    let before = frame(controller.releaseTable.enclosingScrollView!).height
    window.setContentSize(NSSize(width: 1060, height: 900))
    window.contentView?.layoutSubtreeIfNeeded()
    expectFilled("after a resize")
    #expect(frame(controller.releaseTable.enclosingScrollView!).height >= before + 190)
    window.close()
}

/// A sheet opens at the size, column widths and sort it was left at, each kind of sheet its
/// own, saved through the closure as it closes; a size past the screen or under the sheet's
/// minimum is brought within them, and a column the sheet no longer has is ignored (51.38).
@MainActor
@Test func aSheetKeepsItsSizeWidthsAndSortAfterReopening() async throws {
    let tagger = await model(
        Seen(), albums: [], matches: { album, _ in match(album, nil, tier: .noCandidate) })
    let controller = TaggerWindow(model: tagger)
    let window = try #require(controller.window)
    window.orderFront(nil)
    var saved: [TaggerSheetLayouts] = []
    controller.sheetLayoutsChosen = { saved.append($0) }

    click(controller.mappingButton)
    let mapping = try #require(window.attachedSheet?.windowController as? MappingSheet)
    try #require(mapping.window).setContentSize(NSSize(width: 820, height: 410))
    let column = try #require(mapping.table.tableColumns.last)
    column.width = 240
    // As a drag of a column's edge leaves them: the others take up the difference.
    mapping.table.sizeToFit()
    let widths = mapping.table.tableColumns.map(\.width)
    mapping.endSheet()
    try await eventually { saved.count == 1 }
    let layout = try #require(saved.last?.fieldMapping)
    #expect(layout.width == 820 && layout.height == 410)
    #expect(
        mapping.table.tableColumns.map { layout.columns[$0.identifier.rawValue] }
            == widths.map {
                Double($0)
            })
    #expect(saved.last?.otherReleases == nil, "each kind of sheet its own")

    click(controller.mappingButton)
    let reopened = try #require(window.attachedSheet?.windowController as? MappingSheet)
    let sheetWindow = try #require(reopened.window)
    #expect(
        sheetWindow.contentRect(forFrameRect: sheetWindow.frame).size
            == NSSize(width: 820, height: 410))
    #expect(reopened.table.tableColumns.map(\.width) == widths)
    reopened.endSheet()
    window.close()

    let summary = ReleaseSummary(
        id: 1, artist: "Persuader", title: "Stockholm", label: "Svek", catalogNumber: "SK 1",
        country: "Sweden", year: "2000", format: "CD", trackCount: 3)
    let releases = ReleasesSheet(candidates: [(summary, nil)], chosen: 1, title: "Stockholm")
    releases.sort(by: .year, ascending: false)
    var layouts = releases.recorded(in: TaggerSheetLayouts())
    #expect(layouts.otherReleases?.sortColumn == "year")
    #expect(layouts.otherReleases?.sortAscending == false)
    layouts.otherReleases?.columns["gone"] = 99
    layouts.otherReleases?.width = 5000
    layouts.otherReleases?.height = 10
    let again = ReleasesSheet(candidates: [(summary, nil)], chosen: 1, title: "Stockholm")
    again.apply(layouts, room: NSSize(width: 1200, height: 800))
    let size = try #require(again.window).contentRect(forFrameRect: again.window!.frame).size
    #expect(size == NSSize(width: 1200, height: again.window!.minSize.height))
    #expect(again.table.sortDescriptors == [NSSortDescriptor(key: "year", ascending: false)])
    #expect(again.table.tableColumns.allSatisfy { $0.identifier.rawValue != "gone" })
}

/// View Release… clicked twice shows one sheet, and one clicked as Other Releases closes shows
/// none and leaves the next click working.
@MainActor
@Test func viewReleaseShowsOneSheetAndNoneOverAClosedList() async throws {
    let tagger = await analyzed()
    let controller = TaggerWindow(model: tagger)
    let window = try #require(controller.window)
    window.orderFront(nil)
    defer { window.close() }
    click(controller.otherReleasesButton)
    try await eventually { window.attachedSheet?.windowController is ReleasesSheet }
    let releases = try #require(window.attachedSheet?.windowController as? ReleasesSheet)
    let list = try #require(releases.window)

    releases.viewRelease(10)
    releases.viewRelease(10)
    try await eventually { list.attachedSheet?.windowController is ViewReleaseSheet }
    (list.attachedSheet?.windowController as? ViewReleaseSheet)?.endSheet()
    try await eventually { list.attachedSheet == nil }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(list.attachedSheet == nil, "the second click queued nothing")

    releases.viewRelease(10)
    releases.endSheet()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(list.attachedSheet == nil && window.attachedSheet == nil)

    click(controller.otherReleasesButton)
    try await eventually { window.attachedSheet?.windowController is ReleasesSheet }
    let again = try #require(window.attachedSheet?.windowController as? ReleasesSheet)
    again.viewRelease(10)
    try await eventually { again.window?.attachedSheet?.windowController is ViewReleaseSheet }
    (again.window?.attachedSheet?.windowController as? ViewReleaseSheet)?.endSheet()
    again.endSheet()
}

/// The buttons count the other releases and, once the album's files are read, the changes.
@MainActor
@Test func theReviewButtonsCountTheOtherReleasesAndTheChanges() async throws {
    let albums = [
        album(1, "Stockholm", titles: stockholm), album(2, "Second", titles: ["Östermalm"]),
    ]
    let tagger = await model(
        Seen(), albums: albums,
        matches: { album, _ in
            album.id == 1
                ? match(
                    album, release(10, "Stockholm", titles: stockholm), tier: .exact,
                    candidates: Array(11...19))
                : match(
                    album, release(20, "Second", titles: ["Östermalm"]), tier: .exact,
                    candidates: [21])
        },
        files: { ids in
            albums.flatMap { album in album.tracks.indices.map { file(album, $0) } }
                .filter { ids.contains($0.id) }
        })
    tagger.countDelayNanoseconds = 0
    tagger.analyze()
    await tagger.finished()
    tagger.selectedID = 1
    let controller = TaggerWindow(model: tagger)
    defer { controller.window?.close() }
    #expect(controller.otherReleasesButton.title == "9 Other Releases…")
    // Minimal writes the release id, label, catalog number and year to each of the 3 files.
    try await eventually { controller.changesButton.title == "View 12 Changes…" }

    tagger.selectedID = 2
    controller.refresh()
    #expect(controller.otherReleasesButton.title == "1 Other Release…")
    #expect(controller.changesButton.title == "View Changes…", "not read yet")
    try await eventually { controller.changesButton.title == "View 4 Changes…" }

    let (set, _) = try #require(try await tagger.changeSet(for: 2))
    tagger.setExcluded([set.files[0].changes[0].id], for: 2)
    #expect(tagger.changeCounts[2] == nil, "forgotten when the album changes")
    try await eventually { controller.changesButton.title == "View 3 Changes…" }

    #expect(TaggerWindow.otherReleasesTitle(0) == "No Other Releases")
    let none = await model(
        Seen(), albums: [album(3, "Nothing", titles: ["One"])],
        matches: { album, _ in match(album, nil, tier: .noCandidate) })
    none.analyze()
    await none.finished()
    none.tab = .noCandidate
    none.selectedID = 3
    let empty = TaggerWindow(model: none)
    defer { empty.window?.close() }
    #expect(!empty.otherReleasesButton.isEnabled)
    #expect(empty.otherReleasesButton.title == "No Other Releases")
}

/// The window shows a write's progress as the status bar does: a moving bar until the writer
/// reports, then the files written, then the status line once it's done.
@MainActor
@Test func theWindowShowsAWritesProgress() async throws {
    let one = album(1, "Stockholm", titles: stockholm)
    let tagger = await model(
        Seen(), albums: [one],
        matches: { album, _ in
            match(album, release(10, "Stockholm", titles: stockholm), tier: .exact)
        },
        files: { ids in one.tracks.indices.map { file(one, $0) }.filter { ids.contains($0.id) } })
    tagger.analyze()
    await tagger.finished()
    let controller = TaggerWindow(model: tagger)
    defer { controller.window?.close() }
    var report: (TagWriteProgress) -> Void = { _ in }
    var completion: (Set<String>) -> Void = { _ in }
    controller.write = { _, progress, done in
        report = progress
        completion = done
    }
    let plan = try #require(await tagger.plan([1]))
    tagger.apply(plan)
    #expect(!controller.progress.isHidden && controller.progress.isIndeterminate)
    #expect(controller.statusLabel.stringValue == "Writing 12 tags to 3 files…")
    var progress = TagWriteProgress(total: 3)
    progress.read = 3
    progress.written = 1
    report(progress)
    #expect(!controller.progress.isIndeterminate)
    #expect(controller.progress.doubleValue == 4.0 / 6)
    #expect(controller.statusLabel.stringValue == "Writing 12 tags to 3 files: 1 of 3 written")
    completion([])
    #expect(controller.progress.isHidden)
    #expect(
        controller.statusLabel.stringValue
            == "Wrote 12 tags to 3 files; Undo Tag Edit puts them back")
}

/// What the stand-in Look Up Release search was asked.
private final class Queries: @unchecked Sendable {
    // `asked` is guarded by `lock`.
    private let lock = NSLock()
    private var asked: [(ReleaseQuery, [Int64])] = []

    func add(_ query: ReleaseQuery, _ album: DiscogsAlbum) {
        lock.withLock { asked.append((query, album.tracks.map(\.fileID))) }
    }
    var all: [(ReleaseQuery, [Int64])] { lock.withLock { asked } }
}

/// Look Up Release opens on the album's artist and title, asks nothing until Search, lists
/// what it finds and where from, and a release from Discogs is chosen with the API.
@MainActor
@Test func lookUpReleaseSearchesAndChoosesWhatItFinds() async throws {
    let queries = Queries()
    let seen = Seen()
    let summary: @Sendable (Int) -> ReleaseSummary = { id in
        ReleaseSummary(
            id: id, artist: "Persuader", title: "Found \(id)", label: "Svek",
            catalogNumber: "SK \(id)", country: "Sweden", year: "2000", format: "CD",
            trackCount: 1)
    }
    let tagger = await model(
        seen, albums: [album(3, "Nothing", titles: ["One", "Two"])],
        matches: { album, chosen in
            chosen.map { match(album, release($0, "Found", titles: ["One", "Two"]), tier: .exact) }
                ?? match(album, nil, tier: .noCandidate)
        },
        lookUp: { query, album in
            queries.add(query, album)
            return ReleaseLookup(
                releases: [(summary(40), 0.9), (summary(41), 0.5)], origin: .api, isCut: true)
        })
    tagger.analyze()
    await tagger.finished()
    tagger.tab = .noCandidate
    tagger.selectedID = 3
    let controller = TaggerWindow(model: tagger)
    let window = try #require(controller.window)
    window.orderFront(nil)
    defer { window.close() }
    #expect(controller.releaseLine.stringValue == "Look Up… searches the catalog, then Discogs.")
    #expect(controller.lookUpButton.isEnabled)

    click(controller.lookUpButton)
    try await eventually { window.attachedSheet?.windowController is ReleasesSheet }
    let sheet = try #require(window.attachedSheet?.windowController as? ReleasesSheet)
    #expect(sheet.artistField.stringValue == "Persuader")
    #expect(sheet.titleField.stringValue == "Nothing")
    #expect(sheet.shown.isEmpty && queries.all.isEmpty, "nothing asked before Search")
    sheet.catalogNumberField.stringValue = "SK 40"
    await sheet.runSearch()
    #expect(
        queries.all.first?.0
            == ReleaseQuery(
                artist: "Persuader", title: "Nothing", catalogNumber: "SK 40"))
    #expect(queries.all.first?.1 == [300, 301])
    #expect(sheet.shown.map(\.summary.id) == [40, 41])
    #expect(sheet.text(0, .score) == "90%")
    #expect(
        sheet.heading.stringValue == "The catalog has no match; the first 2 releases from Discogs")
    try snapshot(try #require(sheet.window), "discogs-look-up-release")

    sheet.table.selectRowIndexes([0], byExtendingSelection: false)
    sheet.table.sendAction(sheet.table.doubleAction, to: sheet.table.target)
    try await eventually { tagger.selected?.match.releaseID == 40 }
    #expect(seen.chosen.last?.source == .both, "a release from Discogs is loaded from the API")
    #expect(tagger.selected?.review == .chosen(releaseID: 40))
}

/// The first Look Up search, held until the test answers it.
@MainActor
private final class HeldSearch {
    var first: CheckedContinuation<ReleaseLookup, any Error>?
    var calls = 0
}

/// Only the latest search's answer shows: an older one that ends after it, here with the error
/// a cancelled request gives, changes neither the heading nor the button.
@MainActor
@Test func anOlderSearchEndingLateChangesNothing() async throws {
    let held = HeldSearch()
    let summary = ReleaseSummary(
        id: 2, artist: "Persuader", title: "Found", label: "Svek", catalogNumber: "SK 2",
        country: "Sweden", year: "2000", format: "CD", trackCount: 3)
    let sheet = ReleasesSheet(
        candidates: [], chosen: nil, title: "Stockholm",
        lookUp: { _ in
            held.calls += 1
            if held.calls == 1 {
                return try await withCheckedThrowingContinuation { held.first = $0 }
            }
            return ReleaseLookup(releases: [(summary, 0.5)], origin: .catalog, isCut: false)
        },
        query: ReleaseQuery(title: "Stockholm"))
    let first = Task { await sheet.runSearch() }
    try await eventually { held.first != nil }
    await sheet.runSearch()
    #expect(sheet.heading.stringValue == "1 release in the catalog")
    #expect(sheet.searchButton.isEnabled)
    held.first?.resume(throwing: URLError(.cancelled))
    await first.value
    #expect(sheet.heading.stringValue == "1 release in the catalog")
    #expect(sheet.searchButton.isEnabled)
    #expect(sheet.shown.map(\.summary.id) == [2])
}

@MainActor
@Test func lookUpReleaseSaysWhereWhatItFoundCameFrom() {
    let summary = ReleaseSummary(
        id: 1, artist: "", title: "", label: "", catalogNumber: "", country: "", year: "",
        format: "", trackCount: 0)
    let found = { (count: Int, origin: MatchOrigin, cut: Bool) in
        TaggerText.found(
            ReleaseLookup(
                releases: Array(repeating: (summary, 1), count: count), origin: origin,
                isCut: cut))
    }
    #expect(found(1, .catalog, false) == "1 release in the catalog")
    #expect(found(200, .catalog, true) == "The first 200 releases in the catalog")
    #expect(found(3, .api, false) == "The catalog has no match; 3 releases from Discogs")
    #expect(found(0, .api, false) == "Neither the catalog nor Discogs has a match")
}

/// The release area's Open on Discogs is on only for an album with a release, and opens that
/// release's page from the one URL builder.
@MainActor
@Test func openOnDiscogsOpensTheSelectedRelease() async throws {
    let tagger = await analyzed()
    let controller = TaggerWindow(model: tagger)
    defer { controller.window?.close() }
    var opened: [URL] = []
    controller.openURL = { opened.append($0) }
    #expect(controller.discogsButton.isEnabled)
    click(controller.discogsButton)
    #expect(opened.map(\.absoluteString) == [releaseURL(10)])

    let none = await model(
        Seen(), albums: [album(3, "Nothing", titles: ["One"])],
        matches: { album, _ in match(album, nil, tier: .noCandidate) })
    none.analyze()
    await none.finished()
    none.tab = .noCandidate
    none.selectedID = 3
    let empty = TaggerWindow(model: none)
    defer { empty.window?.close() }
    #expect(!empty.discogsButton.isEnabled)
    tagger.selectedID = nil
    controller.refresh()
    #expect(!controller.discogsButton.isEnabled)
}

/// The tagger's own windows are its window and any sheet over it, so Undo Tag Edit pressed in a
/// sheet counts as the tagger's.
@MainActor
@Test func aSheetOverTheTaggerCountsAsItsWindow() async throws {
    let tagger = DiscogsTagger(model: await analyzed())
    #expect(!tagger.isOwnWindow(nil))
    tagger.show()
    let window = try #require(tagger.window)
    defer { window.close() }
    let controller = try #require(window.windowController as? TaggerWindow)
    #expect(tagger.isOwnWindow(window))
    #expect(!tagger.isOwnWindow(NSWindow()))
    click(controller.otherReleasesButton)
    try await eventually { window.attachedSheet?.windowController is ReleasesSheet }
    let releases = try #require(window.attachedSheet?.windowController as? ReleasesSheet)
    let list = try #require(releases.window)
    #expect(tagger.isOwnWindow(list))
    releases.viewRelease(10)
    try await eventually { list.attachedSheet != nil }
    #expect(tagger.isOwnWindow(list.attachedSheet), "a sheet over the sheet")
    (list.attachedSheet?.windowController as? ViewReleaseSheet)?.endSheet()
    releases.endSheet()
}

/// Shown with a selection while an analysis runs, the window keeps the scope of the albums it
/// is matching.
@MainActor
@Test func showingWhileBusyKeepsTheScope() async throws {
    let gate = Gate()
    let tagger = DiscogsTagger(
        model: await model(
            Seen(), albums: [album(1, "Stockholm", titles: stockholm)],
            matches: { album, _ in match(album, nil, tier: .noCandidate) }, gate: gate))
    tagger.show()
    try await eventually { tagger.model.catalog != .checking }
    tagger.model.analyze()
    #expect(tagger.model.isBusy)
    tagger.selectedTracks = { [100] }
    tagger.show()
    #expect(tagger.model.scope == .library)
    gate.open()
    await tagger.model.finished()
    tagger.window?.close()
}

@MainActor
@Test func theMatchedTabAppliesToAllAsExactAndLikelyDo() async throws {
    let tagger = await model(
        Seen(), albums: [album(1, "Stockholm", titles: stockholm)],
        matches: { album, _ in
            match(album, release(10, "Stockholm", titles: stockholm), tier: .matched)
        })
    tagger.analyze()
    await tagger.finished()
    tagger.tab = .matched
    let controller = TaggerWindow(model: tagger)
    #expect(!controller.applyButton.isHidden)
    #expect(controller.applyButton.title == "Apply to All in Matched…")
    #expect(controller.applyButton.isEnabled)
    #expect(tagger.applicable(.matched).map(\.id) == [1])
    controller.window?.close()
}

@MainActor
@Test func aLongReleaseLineTruncatesSoTheWindowStillResizes() async throws {
    let controller = TaggerWindow(model: await analyzed())
    let window = try #require(controller.window)
    let long = String(repeating: "A long reason · ", count: 40)
    for label in [controller.releaseTitle, controller.releaseLine, controller.reasonsLine] {
        label.stringValue = long
    }
    window.layoutIfNeeded()
    // As a drag leaves it: Auto Layout puts the frame back when the content can't fit it.
    for size in [NSSize(width: 900, height: 500), NSSize(width: 1700, height: 950)] {
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        window.layoutIfNeeded()
        #expect(window.frame.size == size)
        #expect(window.contentView?.frame.width == size.width)
    }
    window.close()
}

@MainActor
@Test func theWindowOpensWideEnoughForTheTabsWhereTheScreenHasRoom() async throws {
    let wide = TaggerWindow.openingSize(within: NSRect(x: 0, y: 0, width: 2560, height: 1415))
    #expect(wide == NSSize(width: 1400, height: 760))
    let small = NSRect(x: 0, y: 25, width: 1280, height: 695)
    let fitted = TaggerWindow.openingSize(within: small)
    #expect(fitted.width == 1280)
    #expect(fitted.height < small.height)

    let controller = TaggerWindow(model: await analyzed())
    for (index, tab) in TaggerTab.allCases.enumerated() {
        controller.tabs.setLabel("\(tab.title) (12,345)", forSegment: index)
    }
    #expect(controller.tabs.fittingSize.width < wide.width - 28, "the page's margins")
    controller.window?.close()
}

/// Safe, after Likely, lists the Likely albums whose only reasons are a tie and being found by
/// title, which Likely lists too, and applies to all as the other tabs do; the album list
/// shows each match's confidence between Files and Review (ADR 0170).
@MainActor
@Test func theSafeTabListsTheLikelyAlbumsWhoseEveryTitleFits() async throws {
    let albums = [
        album(1, "Tied", titles: stockholm),
        album(2, "Off", artist: "Abba", titles: stockholm),
        album(3, "Exact", titles: stockholm),
        album(4, "Unknown", artist: "Zed", titles: stockholm),
    ]
    let tagger = await model(
        Seen(), albums: albums,
        matches: { album, _ in
            let release = release(Int(album.id) * 10, album.title, titles: stockholm)
            return switch album.id {
            case 1:
                match(
                    album, release, tier: .likely,
                    reasons: [.tiedAfterTieBreak, .foundByTitleOnly], confidence: 90)
            case 2:
                match(
                    album, release, tier: .likely, reasons: [.titlesDiffer(1), .foundByTitleOnly],
                    confidence: 89)
            case 3: match(album, release, tier: .exact, confidence: 100)
            default: match(album, nil, tier: .noCandidate)
            }
        })
    tagger.analyze()
    await tagger.finished()
    #expect(tagger.albums(in: .safe).map(\.id) == [1])
    #expect(tagger.albums(in: .likely).map(\.id) == [2, 1], "Likely keeps them")

    let controller = TaggerWindow(model: tagger)
    defer { controller.window?.close() }
    #expect(
        controller.albumTable.tableColumns.map(\.title) == [
            "Album", "Files", "Match", "Review",
        ])
    #expect(controller.tabs.label(forSegment: 1) == "Likely (2)")
    #expect(controller.tabs.label(forSegment: 2) == "Safe (1)")
    #expect(controller.text(controller.albumTable, .confidence, 0) == "100%")

    controller.tabs.selectedSegment = 2
    controller.tabs.sendAction(controller.tabs.action, to: controller.tabs.target)
    #expect(tagger.tab == .safe)
    #expect(controller.shownAlbums.map(\.id) == [1])
    #expect(controller.text(controller.albumTable, .confidence, 0) == "90%")
    #expect(!controller.applyButton.isHidden)
    #expect(controller.applyButton.title == "Apply to All in Safe…")
    #expect(controller.applyButton.isEnabled)
    #expect(tagger.applicable(.safe).map(\.id) == [1])

    tagger.tab = .noCandidate
    controller.refresh()
    #expect(controller.text(controller.albumTable, .confidence, 0) == "", "no release, none")
}
