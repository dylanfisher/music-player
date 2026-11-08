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
                ? match(album, release(10, "Stockholm", titles: stockholm), tier: .exact)
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
    #expect(window.sourcePopUp.itemArray.map { $0.isEnabled } == [true, false, false])
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
    #expect(controller.text(controller.trackTable, .state, 0) == "✓")
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
    let sheet = ChangesSheet(set: set, excluded: [], title: "Persuader – Stockholm")
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
            catalogNumber: "SK \(id)", country: country, year: "2000", format: format)
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

@MainActor
@Test func theFieldMappingSheetListsEveryFieldAndEditsTheDraft() throws {
    let sheet = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.oneToOne.mapping, saved: []))
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
        draft: MappingDraft(mapping: DiscogsPreset.oneToOne.mapping, saved: [mine]))
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
    let sheet = MappingSheet(draft: MappingDraft(mapping: mapping, saved: []))
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
        draft: MappingDraft(mapping: DiscogsPreset.oneToOne.mapping, saved: []))
    other.refused = { message, _ in refusals.append(message) }
    other.importFile(at: file)
    #expect(other.draft.mapping == mapping)
    #expect(other.presets.titleOfSelectedItem == "Edited")
    #expect(
        other.problemLabel.stringValue == "Imported “mapping.json”, not saved; Save As keeps it")

    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let pasted = MappingSheet(
        draft: MappingDraft(mapping: DiscogsPreset.minimal.mapping, saved: []))
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
            match: { _, _, _, _ in [] }, summaries: { _ in [] }, read: { _, _ in ([], []) },
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
        .countDiffers(files: 2, tracks: 3), .tracksWithoutFile(1), .durationsDiffer(3),
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
        let tracks = frame(controller.trackTable.enclosingScrollView!)
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

    let before = frame(controller.trackTable.enclosingScrollView!).height
    window.setContentSize(NSSize(width: 1060, height: 900))
    window.contentView?.layoutSubtreeIfNeeded()
    expectFilled("after a resize")
    #expect(frame(controller.trackTable.enclosingScrollView!).height >= before + 190)
    window.close()
}
