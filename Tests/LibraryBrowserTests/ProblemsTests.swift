import AppKit
import Fixtures
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor
private func problemsBrowser() throws -> (LibraryBrowser, LibraryIndex, [Int64]) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let ids = try index.database.prepare("SELECT file_id FROM tracks ORDER BY file_id LIMIT 2")
        .map { try $0.int64(0) }
    return (browser, index, ids)
}

@Test func eachActionAppliesOnlyWhenEveryRowSelectedHasItsFix() {
    let plain = Problem("/M/a.flac: warning tag: cut short")
    let lost = Problem("/M/b.flac: matching tracks: 0", fix: .remove(pathID: 2))
    let removed = Problem("/M/c.flac", fix: .restore(pathID: 3))
    #expect(ProblemAction.dismiss.applies(to: [plain, lost, removed]))
    #expect(!ProblemAction.dismiss.applies(to: []))
    #expect(ProblemAction.remove.applies(to: [lost]))
    #expect(!ProblemAction.remove.applies(to: [lost, plain]))
    #expect(!ProblemAction.remove.applies(to: [removed]))
    #expect(ProblemAction.restore.pathIDs(of: [removed]) == [3])
    #expect(ProblemAction.restore.pathIDs(of: [removed, lost]) == nil)
}

@Test func lostStatsAndRemovedLinesCarryTheirPathsAndTheMoreLineNone() {
    let found = HealthFindings(
        others: (1...(healthLinesListed + 1)).map { "/M/\($0).flac" },
        otherIDs: (1...(healthLinesListed + 1)).map { Int64($0) })
    let lost = healthProblems(found, of: .lostStats)
    #expect(lost.first == Problem("/M/1.flac", kind: "Lost Stats", fix: .remove(pathID: 1)))
    #expect(lost.last == Problem("… and 1 more", kind: "Lost Stats"))
    #expect(healthProblems(found, of: .removed).first?.fix == .restore(pathID: 1))
    #expect(healthProblems(found, of: .unreadable).allSatisfy { $0.fix == nil })
}

@Test func aDismissedLineLeavesTheListAndTheCounts() {
    var status = LibraryStatus()
    status.notices = ["earlier play counts discarded"]
    status.apply(.scanFailed(folder: "/M", reason: "gone"))
    #expect(status.problemsTitle == "1 folder with problems")
    status.dismissed = ["/M: the scan failed: gone"]
    #expect(status.problemLines == ["earlier play counts discarded"])
    #expect(status.problemsTitle == "Show Problems")
    status.dismissed.insert("earlier play counts discarded")
    #expect(!status.hasProblems && status.problemsTitle == nil)
}

@MainActor @Test func dismissingKeepsTheLinesInTheLibrary() async throws {
    let (browser, index, _) = try problemsBrowser()
    await browser.fix([Problem("/M/a.flac: warning tag: cut short")], by: .dismiss)
    #expect(try index.dismissedProblems() == ["/M/a.flac: warning tag: cut short"])
    #expect(browser.status.dismissed == ["/M/a.flac: warning tag: cut short"])
}

@MainActor @Test func removingALostPathTakesItOutOfLostStatsAndIntoRemoved() async throws {
    let (browser, index, ids) = try problemsBrowser()
    try index.setRating(3, trackIDs: [ids[0]])
    try index.deleteFile(ids[0])
    #expect(try index.lostFiles().map(\.id) == [ids[0]])
    await browser.fix([Problem("lost", fix: .remove(pathID: ids[0]))], by: .remove)
    #expect(try index.lostFiles().isEmpty)
    #expect(try index.removedPaths().map(\.id) == [ids[0]])
}

@MainActor @Test func theButtonsFollowTheSelectionAndActOnIt() throws {
    let window = ProblemsWindow()
    var acted: [(ProblemAction, [Problem])] = []
    window.act = { acted.append(($0, $1)) }
    let rows = [Problem("plain"), Problem("lost", fix: .remove(pathID: 7))]
    window.show(rows)
    defer { window.window.close() }
    // Only Dismiss All acts with no row selected.
    #expect(window.buttons.filter { $0.value.isEnabled }.map(\.key) == [.dismissAll])
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(window.buttons[.remove]?.isEnabled == true)
    #expect(window.buttons[.restore]?.isEnabled == false)
    try click(#require(window.buttons[.remove]))
    #expect(acted.count == 1 && acted[0].0 == .remove && acted[0].1 == [rows[1]])
    window.table.selectRowIndexes([0, 1], byExtendingSelection: false)
    #expect(window.buttons[.remove]?.isEnabled == false)
    #expect(window.buttons[.dismiss]?.isEnabled == true)
    // A refresh keeps the rows still listed selected.
    window.refresh([rows[1]])
    #expect(window.selected == [rows[1]])
}

/// Library Problems is a document window: it doesn't float over other windows or hide with
/// the app.
@MainActor @Test func theProblemsWindowIsANormalWindow() {
    let window = ProblemsWindow()
    window.show([Problem("plain")])
    defer { window.window.close() }
    #expect(!(window.window is NSPanel))
    #expect(window.window.level == .normal)
    #expect(!window.window.hidesOnDeactivate)
    #expect(window.window.styleMask.contains(.miniaturizable))
}

/// Dismiss All acts on every row, whether none, some or all are selected, and only while the
/// window lists any.
@MainActor @Test func dismissAllActsOnEveryRowSelectedOrNot() throws {
    let window = ProblemsWindow()
    var acted: [(ProblemAction, [Problem])] = []
    window.act = { acted.append(($0, $1)) }
    let rows = [Problem("plain"), Problem("lost", fix: .remove(pathID: 7)), Problem("other")]
    window.show(rows)
    defer { window.window.close() }
    #expect(window.buttons[.dismissAll]?.title == "Dismiss All")
    for selection in [IndexSet(), [1], [0, 1, 2]] {
        window.table.selectRowIndexes(selection, byExtendingSelection: false)
        #expect(window.buttons[.dismissAll]?.isEnabled == true)
        try click(#require(window.buttons[.dismissAll]))
        #expect(acted.last?.0 == .dismissAll && acted.last?.1 == rows, "\(Array(selection))")
    }
    window.refresh([])
    #expect(window.buttons[.dismissAll]?.isEnabled == false)
    try click(#require(window.buttons[.dismissAll]))
    #expect(acted.count == 3)
}

@MainActor @Test func dismissingAllKeepsEveryLineInTheLibrary() async throws {
    let (browser, index, _) = try problemsBrowser()
    let lines = ["/M/a.flac: warning tag: cut short", "/M: the scan failed: gone"]
    await browser.fix(lines.map { Problem($0) }, by: .dismissAll)
    #expect(try index.dismissedProblems() == Set(lines))
    #expect(browser.status.dismissed == Set(lines))
}

@Test func anImportsListedMissesOfferLocateAndOnlyOneAtATime() {
    var plan = ImportPlan(
        library: PlayerLibrary(player: .swinsian, source: "/s/Library.sqlite"), prefix: nil)
    plan.unmatched = ["/Old/a.flac", "/Old/b.flac"]
    plan.unreadFormat = ["/Old/c.ogg"]
    let rows = plan.problems
    #expect(rows.map(\.line) == plan.detailLines)
    #expect(rows[0].fix == .locate(path: "/Old/a.flac"))
    #expect(rows[2].fix == nil)
    #expect(ProblemAction.locate.missingPath(of: [rows[1]]) == "/Old/b.flac")
    #expect(!ProblemAction.locate.applies(to: [rows[0], rows[1]]))
    #expect(!ProblemAction.locate.applies(to: [rows[2]]))
}

/// A browser whose last import missed the first track, at a path under `/Old` in a folder of
/// the same name as the track's.
@MainActor
private func locatingBrowser() throws -> (
    LibraryBrowser, LibraryIndex, id: Int64, miss: String, folder: URL
) {
    let (browser, index, ids) = try problemsBrowser()
    let path = try #require(try index.paths(ids: [ids[0]])[ids[0]])
    let folder = (path as NSString).deletingLastPathComponent
    let miss =
        "/Old/" + (folder as NSString).lastPathComponent + "/"
        + (path as NSString).lastPathComponent
    var source = PlayerLibrary(player: .swinsian, source: "/s/Library.sqlite")
    var track = PlayerTrack(path: miss)
    track.plays = 5
    _ = source.add(track)
    var plan = ImportPlan(library: source, prefix: nil)
    plan.unmatched = [miss]
    browser.lastImport = plan
    return (browser, index, ids[0], miss, URL(fileURLWithPath: folder, isDirectory: true))
}

@MainActor @Test func locatingInAWatchedFolderMatchesTheMissAgain() async throws {
    let (browser, index, id, miss, folder) = try locatingBrowser()
    browser.watchedFolders = { [WatchedFolder(path: "/", kind: .local)] }
    await browser.locate(miss, in: folder)
    #expect(try index.rows(ids: [id])[0].playCount == 5)
    #expect(browser.lastImport?.unmatched == [])
    #expect(browser.statusText == "Located 1 of 1 track in \(folder.path)")
}

@MainActor @Test func locatingOutsideTheWatchedFoldersWatchesThenMatchesAfterTheScan()
    async throws
{
    let (browser, index, id, miss, folder) = try locatingBrowser()
    browser.watchedFolders = { [] }
    var watched: [URL] = []
    browser.watch = { watched.append($0) }
    browser.confirmWatch = { _, _, answer in answer(true) }
    // The question goes over the Problems window, so it has to be open.
    browser.showProblems()
    try await waitFor("the Problems window") { browser.problems != nil }
    await browser.locate(miss, in: folder)
    #expect(watched == [folder])
    #expect(try index.rows(ids: [id])[0].playCount == 0)
    browser.libraryChanged(.scanned(folder: folder.path, ScanSummary()))
    try await waitFor("the match") { try index.rows(ids: [id])[0].playCount == 5 }
    browser.problems?.window.close()
}

@MainActor @Test func aFailedScanOfTheFolderDropsTheWaitingLocate() async throws {
    let (browser, index, id, miss, folder) = try locatingBrowser()
    browser.watchedFolders = { [] }
    browser.watch = { _ in }
    browser.confirmWatch = { _, _, answer in answer(true) }
    browser.showProblems()
    try await waitFor("the Problems window") { browser.problems != nil }
    await browser.locate(miss, in: folder)
    #expect(browser.pendingLocate != nil)
    browser.libraryChanged(.scanFailed(folder: folder.path, reason: "disk I/O error"))
    #expect(browser.pendingLocate == nil)
    // A later scan of the folder doesn't match the miss on its own.
    browser.libraryChanged(.scanned(folder: folder.path, ScanSummary()))
    #expect(try index.rows(ids: [id])[0].playCount == 0)
    browser.problems?.window.close()
}

/// Each part of a problem in its column, said plainly, whichever place it came from.
@Test func eachKindOfProblemFillsTheColumns() {
    func columns(_ problem: Problem) -> [String] { ProblemColumn.allCases.map { $0.text(problem) } }
    let failure = Problem(
        FileIssue(path: "/M/A/a.flac", problem: .failure(.malformed), offset: 12, detail: "bad"))
    #expect(
        columns(failure) == [
            "Can't read", "", "a.flac", "/M/A", "the file is damaged: bad (at byte 12)",
        ])
    #expect(failure.line == "/M/A/a.flac: failure malformed: bad (at byte 12)")
    let warning = Problem(
        FileIssue(path: "/M/b.flac", problem: .warning(.badNumber), offset: nil, detail: "x"))
    #expect(warning.kind == "Tag warning" && warning.detail.hasPrefix("a track or disc number"))
    let folder = Problem(ScanIssue(kind: .rootUnavailable, path: "/Volumes/music", detail: "gone"))
    #expect(columns(folder) == ["Folder not there", "", "music", "/Volumes", "gone"])
    let organized = Problem("/l/b.flac: not moved, /l/A/b.flac is already there")
        .kinded(ProblemKind.organized)
    #expect(
        columns(organized) == [
            "Organizing", "", "b.flac", "/l", "not moved, /l/A/b.flac is already there",
        ])
    #expect(
        columns(Problem("the sync failed: no folder", kind: "Sync")) == [
            "Sync", "", "", "", "the sync failed: no folder",
        ])
    var plan = ImportPlan(
        library: PlayerLibrary(player: .swinsian, source: "/s/Library.sqlite"), prefix: nil)
    plan.unmatched = ["/Old/a.flac"]
    #expect(
        columns(plan.problems[0]).suffix(3) == [
            "a.flac", "/Old", "not in the library, in /s/Library.sqlite",
        ])
}

/// The status's rows each say which report they're from.
@Test func theStatusesRowsSayWhereTheyreFrom() {
    var status = LibraryStatus()
    status.notices = ["earlier play counts discarded"]
    status.addedFilesReport = [Problem("/a.mp3: not added")]
    status.apply(.scanFailed(folder: "/M", reason: "gone"))
    #expect(status.problems.map(\.kind) == ["Notice", "Adding files", "Scan failed"])
    #expect(status.problems.last?.path == "/M" && status.problems.last?.detail == "gone")
    #expect(status.problemLines.last == "/M: the scan failed: gone")
}

@MainActor @Test func theTableSortsByAnyColumnAndKeepsTheSelection() throws {
    let window = ProblemsWindow()
    let rows = [
        Problem("/M/b.flac: second", kind: "Tag warning"),
        Problem("/M/c.flac: first", kind: "Can't read"),
        Problem("/M/a.flac: third", kind: "Tag warning"),
    ]
    window.show(rows)
    defer { window.window.close() }
    #expect(
        window.table.tableColumns.map(\.title) == ["Kind", "Track", "File", "Folder", "Detail"])
    #expect(window.table.headerView != nil)
    window.table.selectRowIndexes([0], byExtendingSelection: false)
    window.table.sortDescriptors = [NSSortDescriptor(key: "file", ascending: true)]
    #expect(window.rows.map(\.path) == ["/M/a.flac", "/M/b.flac", "/M/c.flac"])
    #expect(window.selected == [rows[0]])
    window.table.sortDescriptors = [NSSortDescriptor(key: "detail", ascending: false)]
    #expect(window.rows.map(\.detail) == ["third", "second", "first"])
    // Rows the column holds the same keep the order they came in.
    window.table.sortDescriptors = [NSSortDescriptor(key: "kind", ascending: true)]
    #expect(window.rows == [rows[1], rows[0], rows[2]])
    // A refresh keeps the sort.
    window.refresh(Array(rows.reversed()))
    #expect(window.rows == [rows[1], rows[2], rows[0]])
}

@MainActor @Test func theColumnWidthsKeptAreAppliedAndAResizeReported() throws {
    let window = ProblemsWindow()
    var reported: [ColumnWidths] = []
    window.columnsResized = { reported.append($0) }
    window.show([Problem("plain")], widths: ColumnWidths(["kind": 150, "gone": 90]))
    defer { window.window.close() }
    let kind = try #require(window.table.tableColumn(withIdentifier: .init("kind")))
    #expect(kind.width == 150)
    #expect(reported.isEmpty)
    kind.width = 180
    #expect(reported.last?.widths["kind"] == 180)
    #expect(reported.last?.widths.keys.sorted() == ProblemColumn.allCases.map(\.rawValue).sorted())
}

/// The browser lists each problem with the track the index has at its path, and keeps the
/// widths the window reports.
@MainActor @Test func theProblemsWindowNamesTheTrackAndKeepsItsWidths() async throws {
    let (browser, index, ids) = try problemsBrowser()
    let path = try #require(try index.paths(ids: [ids[0]])[ids[0]])
    let row = try #require(try index.rows(ids: [ids[0]]).first)
    browser.finishAdding("Added", [Problem(path + ": not added")])
    try await waitFor("the Problems window") { browser.problems?.rows.isEmpty == false }
    let window = try #require(browser.problems)
    defer { window.window.close() }
    let listed = try #require(window.rows.first { $0.path == path })
    #expect(listed.track == [row.artist, row.title].compactMap { $0 }.joined(separator: " – "))
    var kept: [ColumnWidths] = []
    browser.problemColumnsChanged = { kept.append($0) }
    window.table.tableColumns[0].width = 140
    #expect(kept.last?.widths["kind"] == 140)
    #expect(browser.problemColumns == kept.last)
}
