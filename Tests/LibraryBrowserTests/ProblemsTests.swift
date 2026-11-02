import AppKit
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
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false)
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
    #expect(lost.first == Problem("/M/1.flac", fix: .remove(pathID: 1)))
    #expect(lost.last == Problem("… and 1 more"))
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
    #expect(window.buttons.values.allSatisfy { !$0.isEnabled })
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(window.buttons[.remove]?.isEnabled == true)
    #expect(window.buttons[.restore]?.isEnabled == false)
    window.buttons[.remove]?.performClick(nil)
    #expect(acted.count == 1 && acted[0].0 == .remove && acted[0].1 == [rows[1]])
    window.table.selectRowIndexes([0, 1], byExtendingSelection: false)
    #expect(window.buttons[.remove]?.isEnabled == false)
    #expect(window.buttons[.dismiss]?.isEnabled == true)
    // A refresh keeps the rows still listed selected.
    window.refresh([rows[1]])
    #expect(window.selected == [rows[1]])
}
