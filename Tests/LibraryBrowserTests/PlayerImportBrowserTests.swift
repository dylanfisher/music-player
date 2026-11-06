import AppKit
import Fixtures
import Foundation
import SQLite
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

private func emptyPlan(_ prefix: PathPrefix? = nil) -> ImportPlan {
    ImportPlan(
        library: PlayerLibrary(player: .swinsian, source: "/s/Library.sqlite"), prefix: prefix)
}

@MainActor @Test func aSlowEarlierPreviewNeverReplacesALaterOne() async throws {
    let slow = PathPrefix(from: "/slow", to: "/a")
    let fast = PathPrefix(from: "/fast", to: "/b")
    let session = PlayerImportSession(shown: emptyPlan()) { prefix in
        if prefix == slow { try await Task.sleep(nanoseconds: 300_000_000) }
        return emptyPlan(prefix)
    }
    let earlier = Task { try await session.preview(slow) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let later = try await session.preview(fast)
    #expect(later?.prefix == fast)
    #expect(try await earlier.value == nil)
    #expect(session.shown?.prefix == fast && !session.isPreviewing)
}

@MainActor @Test func aFailedPreviewClearsThePlanShown() async throws {
    struct Failure: Error {}
    let session = PlayerImportSession(shown: emptyPlan()) { _ in throw Failure() }
    await #expect(throws: Failure.self) {
        try await session.preview(PathPrefix(from: "/x", to: "/y"))
    }
    #expect(session.shown == nil && !session.isPreviewing)
}

@Test func theImportReportEscapesNamesAndCapsEachList() throws {
    var plan = emptyPlan()
    plan.unmatched = (1...150).map { "/gone/\($0).flac" }
    plan.unreadFormat = ["/ogg/1.ogg"]
    plan.existingPlaylists = ["Mix\nfake row"]
    plan.library.playlists = [
        PlayerPlaylist(name: "Odd", kind: .unmapped(["the field “kind” has no match here"]))
    ]
    plan.library.problems = [PlayerLibraryProblem("track 3", .noPath)]
    plan.library.unlistedProblemCount = 2
    plan.ratings = 3
    plan.roundedRatings = 2
    #expect(
        plan.preview.rows.contains(
            ImportPreview.Row(change: "Ratings", count: "3 tracks, 2 from a half star rounded up")))
    let lines = plan.detailLines
    let source = "/s/Library.sqlite"
    #expect(lines.filter { $0.hasPrefix("\(source): not in the library: ") }.count == 100)
    #expect(lines.contains("\(source): 50 more not in the library"))
    #expect(
        lines.contains(
            "\(source): not in the library, a format this app doesn't read yet: /ogg/1.ogg"))
    #expect(
        plan.preview.heading
            == "0 tracks read: 0 in this library, 151 not, 1 of them in a format not read yet")
    #expect(lines.contains("\(source): not made, a playlist has the name: Mix\\u{A}fake row"))
    #expect(
        lines.contains(
            "\(source): smart playlist not made, its rules don't map: Odd (the field “kind” has no match here)"
        ))
    #expect(
        lines.suffix(2) == ["\(source): track 3: has no file path", "\(source): 2 more problems"])
    #expect(
        plan.preview.notes.contains(
            "Playlists skipped: 1 with a name already used here, 1 with rules that don't map"))
}

/// The preview's table has a row for each field that changes, Skip counts only from iTunes,
/// which keeps them; the fields that change nothing share one line, and what's left out is a
/// note under the table.
@Test func thePreviewListsWhatChangesAndGroupsTheRest() {
    var plan = emptyPlan()
    plan.library.tracks = (1...3).map { PlayerTrack(path: "/m/\($0).flac") }
    plan.matched = 2
    plan.unmatched = ["/m/3.flac"]
    plan.playsAdded = 1204
    plan.tracksGainingPlays = 2
    plan.datedLastPlays = 2
    plan.ratingsKept = 1
    plan.mergedRows = 32
    plan.playlists = [PlannedPlaylist(name: "Mix", kind: .manual([]))]
    let preview = plan.preview
    #expect(preview.heading == "3 tracks read: 2 in this library, 1 not")
    #expect(
        preview.rows == [
            ImportPreview.Row(change: "Play counts", count: "+1,204 on 2 tracks"),
            ImportPreview.Row(change: "Last plays dated in Listening Stats", count: "2 tracks"),
            ImportPreview.Row(change: "New playlists", count: "1"),
        ])
    #expect(preview.unchanged == "No change: last played, date added, ratings, loved")
    #expect(
        preview.notes == [
            "Ratings kept on 1 track, rated differently here",
            "32 rows for a track already read, merged into it",
        ])
    plan.library.player = .iTunes
    #expect(
        plan.preview.unchanged == "No change: skip counts, last played, date added, ratings, loved")
    plan.skipsAdded = 5
    plan.tracksGainingSkips = 1
    #expect(
        plan.preview.rows[1] == ImportPreview.Row(change: "Skip counts", count: "+5 on 1 track"))
}

@MainActor @Test func anAppliedImportShowsItsPlaysAndPlaylists() async throws {
    let (model, index) = try await writableModel()
    let ids = Array(model.trackIDs.prefix(2))
    let paths = try index.paths(ids: ids)
    let quoted = ids.map { paths[$0]!.replacingOccurrences(of: "'", with: "''") }
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-import-browser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("Library.sqlite")
    let database = try Database(at: url)
    try database.execute(
        swinsianSchemaSQL
            + """
            INSERT INTO track (track_id, path, playcount, rating, favourite)
                VALUES (1, '\(quoted[0])', 7, 3, 0), (2, '\(quoted[1])', 0, 0, 1);
            INSERT INTO playlist (playlist_id, name, smart) VALUES (1, 'From Swinsian', 0);
            INSERT INTO playlisttrack (playlist_id, track_id, tindex) VALUES (1, 2, 1), (1, 1, 2);
            """)
    let library = try PlayerLibrary.read(.swinsian, at: url)
    let preview = try await model.importPlan(library, prefix: nil)
    #expect(preview.playsAdded == 7 && preview.ratings == 1 && preview.loved == 1)
    let written = try await model.applyImport(library, prefix: nil)
    #expect(
        written.summary
            == "Imported from Swinsian: +7 plays on 1 track · 1 rating · 1 loved · 1 playlist")
    let made = try #require(model.playlists.first { $0.name == "From Swinsian" })
    #expect(try index.playlistTrackIDs(made.id) == [ids[1], ids[0]])
    #expect(try index.rows(ids: [ids[0]])[0].playCount == 7)
}

/// A browser on a writable library, a Swinsian library giving its first track 4 plays, and
/// Swinsian preferences with `columns`, sorted by year descending, in a temporary folder.
@MainActor private func swinsianImport(columns: [(id: String, width: Double)]) throws -> (
    browser: LibraryBrowser, index: LibraryIndex, id: Int64, library: URL
) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let id = try #require(try index.trackIDs(sortedBy: .path).first)
    let path = try #require(try index.paths(ids: [id])[id])
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-import-sheet-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("Library.sqlite")
    try Database(at: url).execute(
        swinsianSchemaSQL + "INSERT INTO track (track_id, path, playcount) VALUES"
            + " (1, '\(path.replacingOccurrences(of: "'", with: "''"))', 4);")
    browser.swinsianPreferences = folder.appendingPathComponent("prefs.plist", isDirectory: false)
    try swinsianPreferences(columns: columns, sort: ("year", false))
        .write(to: browser.swinsianPreferences)
    return (browser, index, id, url)
}

/// Opens the import of `library`, runs `choose` on its sheet, clicks Import and waits for the
/// report.
@MainActor private func confirmImport(
    _ browser: LibraryBrowser, _ library: URL, _ choose: (PlayerImportSheet) -> Void = { _ in }
) async throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
        backing: .buffered, defer: false)
    browser.importLibrary(.swinsian, from: library, over: window)
    let deadline = Date().addingTimeInterval(10)
    while browser.importSheet == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let sheet = try #require(browser.importSheet, "no sheet; status: \(browser.statusText)")
    choose(sheet)
    window.endSheet(sheet.alert.window, returnCode: .alertFirstButtonReturn)
    while !browser.statusText.hasPrefix("Imported from"), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor @Test func importLibraryReadsPreviewsAndWritesOnImport() async throws {
    let (browser, index, id, library) = try swinsianImport(columns: [("title", 300)])
    var saved: [TrackTableLayout] = []
    browser.tableLayoutChanged = { saved.append($0) }
    try await confirmImport(browser, library) { _ in
        #expect((try? index.rows(ids: [id])[0].playCount) == 0)
    }
    #expect(browser.statusText == "Imported from Swinsian: +4 plays on 1 track · 0 playlists")
    #expect(try index.rows(ids: [id])[0].playCount == 4)
    #expect(browser.importSheet == nil)
    // Import column layout was left off.
    #expect(saved.isEmpty && browser.table.layout == AppState().trackTable.defaultValue)
}

@MainActor @Test func importColumnLayoutShowsAndSavesSwinsiansColumns() async throws {
    let (browser, _, _, library) = try swinsianImport(columns: [
        ("artwork", 160), ("currentlyPlaying", 64), ("year", 56), ("title", 390),
    ])
    var saved: [TrackTableLayout] = []
    browser.tableLayoutChanged = { saved.append($0) }
    try await confirmImport(browser, library) { sheet in
        #expect(sheet.columnsBox.isEnabled)
        sheet.columnsBox.performClick(nil)
    }
    #expect(
        browser.statusText
            == "Imported from Swinsian: +4 plays on 1 track · 0 playlists · column layout")
    let expected = TrackTableLayout(
        columns: [
            ColumnLayout(column: .art, width: 160), ColumnLayout(column: .year, width: 56),
            ColumnLayout(column: .title, width: 390),
        ], sortColumn: .year, sortAscending: false)
    #expect(browser.table.layout == expected)
    #expect(saved == [expected])
    #expect(
        browser.status.playlistFileReport.contains {
            $0.line.hasSuffix("prefs.plist: column layout: currentlyPlaying: no such column here")
        })
}

@MainActor @Test func theDetailsListSkippedColumnsOnlyWithImportColumnLayoutOn() throws {
    let plan = emptyPlan()
    let columns = try SwinsianColumns(
        preferences: try swinsianPreferences(
            columns: [("currentlyPlaying", 64), ("title", 390)], sort: ("artist", true)),
        source: "/p.plist")
    let sheet = PlayerImportSheet(
        session: PlayerImportSession(shown: plan) { _ in plan }, player: .swinsian,
        columns: .success(columns))
    let skipped = "/p.plist: column layout: currentlyPlaying: no such column here"
    #expect(sheet.details.string == "Every track matched.")
    sheet.columnsBox.performClick(nil)
    #expect(sheet.details.string.contains(skipped))
}

@MainActor @Test func theSheetFitsA1440x900ScreenWithEverythingFilled() throws {
    var plan = emptyPlan()
    // Every field changing but Loved, so the table and the line for what doesn't change both
    // show.
    plan.library.tracks = (1...12_000).map { PlayerTrack(path: "/m/\($0).flac") }
    plan.matched = 11_700
    plan.unmatched = (1...300).map {
        "/Volumes/music/library/Some Very Long Artist Name/An Album Title (Deluxe Edition)/\($0) A Track.flac"
    }
    (plan.playsAdded, plan.tracksGainingPlays) = (48_210, 9_310)
    (plan.lastPlayed, plan.datedLastPlays, plan.dateAdded) = (9_002, 8_950, 11_204)
    (plan.ratings, plan.roundedRatings, plan.ratingsKept) = (2_400, 120, 18)
    plan.playlists = [
        PlannedPlaylist(name: "Mix", kind: .manual([])),
        PlannedPlaylist(name: "Recent", kind: .manual([]), wasSmart: true),
    ]
    plan.existingPlaylists = ["Mix"]
    plan.library.builtInPlaylists = 4
    plan.library.tracksWithoutFiles = 3
    plan.mergedRows = 32
    plan.library.unlistedProblemCount = 2
    let columns = try SwinsianColumns(
        preferences: try swinsianPreferences(
            columns: [("artwork", 160), ("currentlyPlaying", 64), ("title", 390)],
            sort: ("artist", true)),
        source: "/Users/someone/Library/Preferences/com.swinsian.Swinsian.plist")
    let sheet = PlayerImportSheet(
        session: PlayerImportSession(shown: plan) { _ in plan }, player: .swinsian,
        columns: .success(columns))
    sheet.fromField.stringValue = "/Volumes/Old Music Drive/iTunes/iTunes Media/Music"
    sheet.toField.stringValue = "/Volumes/music/library"
    sheet.alert.layout()
    #expect(sheet.changes.numberOfRows == 6)
    let firstRow = (0..<2).map {
        (sheet.changes.cell(atColumnIndex: $0, rowIndex: 0).contentView as? NSTextField)?
            .stringValue
    }
    #expect(firstRow == ["Play counts", "+48,210 on 9,310 tracks"])
    #expect(
        !sheet.unchangedLabel.isHidden && sheet.unchangedLabel.stringValue == "No change: loved")
    #expect(!sheet.notesLabel.isHidden)
    let frame = sheet.alert.window.frame
    // Room to spare for iTunes' row of skip counts, in place of the column layout's row.
    #expect(frame.width <= 1440 && frame.height <= 900 - 25 - 30, "\(frame)")
    let accessory = try #require(sheet.alert.accessoryView)
    #expect(accessory.fittingSize.width <= PlayerImportSheet.width + 1, "\(accessory.fittingSize)")
    #expect(sheet.toField.frame.width > 100, "\(sheet.toField.frame)")
    // A picture of the sheet for review, under .build.
    let view = try #require(sheet.alert.window.contentView)
    let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/snapshots/player-import-sheet.png")
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #require(image.representation(using: .png, properties: [:])).write(to: out)
}
