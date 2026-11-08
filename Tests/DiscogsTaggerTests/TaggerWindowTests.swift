import AppKit
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
    #expect(window.sourcePopUp.itemArray.map { $0.isEnabled } == [true, false, false])
    window.window?.close()
}

@MainActor
@Test func theTabsCountTheTiersAndTheSelectedAlbumShowsItsTracklists() async throws {
    let tagger = await analyzed()
    let controller = TaggerWindow(model: tagger)
    let window = try #require(controller.window)
    #expect(controller.catalogBox.isHidden)
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
@Test func viewChangesTicksEachChangeAndCountsThem() throws {
    let change = { (file: Int64, field: DiscogsField, tag: String) in
        TagChange(
            id: TagChange.ID(fileID: file, tag: .custom(tag)), field: field, current: nil,
            new: "1")
    }
    let set = AlbumChangeSet(files: [
        FileChanges(
            fileID: 1, path: "/m/1.flac",
            changes: [change(1, .releaseID, "DISCOGS_RELEASE_ID"), change(1, .label, "LABEL")],
            unwritable: nil, tags: TrackTags()),
        FileChanges(
            fileID: 2, path: "/m/2.dsf", changes: [], unwritable: "Tags in DSD files can't be",
            tags: TrackTags()),
    ])
    let sheet = ChangesSheet(set: set, excluded: [], title: "Persuader – Stockholm")
    #expect(sheet.rows.count == 3)
    #expect(sheet.summary.stringValue == "2 of 2 changes in 1 file")
    sheet.toggle(1)
    #expect(sheet.excluded == [TagChange.ID(fileID: 1, tag: .custom("LABEL"))])
    #expect(sheet.summary.stringValue == "1 of 2 changes in 1 file")
    sheet.toggle(2)
    #expect(sheet.excluded.count == 1, "a file nothing is written to has no box")
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
