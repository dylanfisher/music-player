import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor
private func rescanningBrowser() throws -> (LibraryBrowser, LibraryIndex) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    return (browser, index)
}

/// A rescan that records the paths it's given and answers `reply`.
@MainActor
private final class RecordedRescan {
    var given: [[String]] = []
    var reply: Result<ScanSummary, any Error> = .success(ScanSummary())

    var rescan: FileRescan {
        { [self] paths, done in
            given.append(paths)
            done(reply)
        }
    }
}

/// On only with tracks selected, it hands over the selected tracks' paths in table order.
@MainActor @Test func rescanSelectedFilesReadsTheSelectedTracks() async throws {
    let (browser, index) = try rescanningBrowser()
    await browser.load(BrowserState(source: nil))
    #expect(!browser.hasSelectedTracks)
    browser.selectAllTracks()
    #expect(browser.hasSelectedTracks)
    let recorded = RecordedRescan()
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the rescan") { !recorded.given.isEmpty }
    #expect(recorded.given == [try await browser.selectedPaths()])
    #expect(recorded.given.first?.count == (try index.trackCount()))
}

/// The timeline's rows are plays: a track played twice is read once.
@MainActor @Test func rescanSelectedFilesReadsATimelineRowsTracksOnce() async throws {
    let (browser, index) = try rescanningBrowser()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    // Newest first: b, a, a.
    for (seconds, row) in [rows[0], rows[0], rows[1]].enumerated() {
        try index.recordPlay(row.path, at: Double(seconds))
    }
    await browser.load(BrowserState(source: .timeline))
    try await waitFor("the plays") { browser.timelineModel.entries.count == 3 }
    browser.selectAllTracks()
    let recorded = RecordedRescan()
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the rescan") { !recorded.given.isEmpty }
    #expect(recorded.given == [[rows[1].path, rows[0].path]])
}

/// A file gone from the disk is listed in the Problems window as a folder scan lists it, and
/// the status bar counts what was read.
@MainActor @Test func rescanSelectedFilesReportsAFileItCouldntRead() async throws {
    let (browser, _) = try rescanningBrowser()
    await browser.load(BrowserState(source: nil))
    browser.selectAllTracks()
    let gone = try #require(try await browser.selectedPaths().first)
    let issue = ScanIssue(kind: .unreadable, path: gone, detail: "no such file")
    var summary = ScanSummary()
    summary.read = 2
    summary.issues = [issue]
    let recorded = RecordedRescan()
    recorded.reply = .success(summary)
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the report") { !browser.status.rescannedReport.isEmpty }
    #expect(browser.status.rescannedReport == [Problem(issue)])
    #expect(browser.status.problemLines.contains(issue.description))
    #expect(browser.statusText == "Read 2 files again; 1 problem")

    // The next one's report takes its place.
    recorded.reply = .success(ScanSummary())
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the next report") { browser.status.rescannedReport.isEmpty }
    #expect(browser.statusText == "Read 0 files again")
}

@MainActor @Test func aRescanThatFailsSaysWhy() async throws {
    let (browser, _) = try rescanningBrowser()
    await browser.load(BrowserState(source: nil))
    browser.selectAllTracks()
    let recorded = RecordedRescan()
    recorded.reply = .failure(TestFailure())
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the failure") { browser.statusText.contains("couldn't read") }
    #expect(browser.statusText == "couldn't read the selected files again: the disk is full")
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String { "the disk is full" }
}

@Test func theRescanLineCountsTheFilesAndTheProblems() {
    var summary = ScanSummary()
    summary.read = 1
    #expect(rescannedSummary(summary) == "Read 1 file again")
    summary.read = 1_200
    summary.failed = 2
    summary.issues = [ScanIssue(kind: .unreadable, path: "/m/a.flac", detail: "gone")]
    #expect(rescannedSummary(summary) == "Read 1,200 files again; 3 problems")
}
