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
    /// What it answers at once; nil keeps each answer in `held` for the test to give.
    var reply: Result<ScanSummary, any Error>? = .success(ScanSummary())
    var held: [@Sendable (Result<ScanSummary, any Error>) -> Void] = []

    var rescan: FileRescan {
        { [self] paths, done in
            given.append(paths)
            if let reply { done(reply) } else { held.append(done) }
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

/// A failure says why, and takes away the last rescan's problems, which aren't its own.
@MainActor @Test func aRescanThatFailsSaysWhy() async throws {
    let (browser, _) = try rescanningBrowser()
    await browser.load(BrowserState(source: nil))
    browser.selectAllTracks()
    let recorded = RecordedRescan()
    var summary = ScanSummary()
    summary.issues = [ScanIssue(kind: .unreadable, path: "/m/a.flac", detail: "gone")]
    recorded.reply = .success(summary)
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the report") { !browser.status.rescannedReport.isEmpty }
    recorded.reply = .failure(TestFailure())
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the failure") { browser.statusText.contains("couldn't read") }
    #expect(browser.statusText == "couldn't read the selected files again: the disk is full")
    #expect(browser.status.rescannedReport.isEmpty)
}

/// A rescan begun while another runs keeps saying it's reading when the first one ends; the
/// report is the last one to end.
@MainActor @Test func anEarlierRescansEndDoesntHideALaterOneRunning() async throws {
    let (browser, _) = try rescanningBrowser()
    await browser.load(BrowserState(source: nil))
    browser.selectAllTracks()
    let count = try await browser.selectedPaths().count
    let recorded = RecordedRescan()
    recorded.reply = nil
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the first rescan") { recorded.held.count == 1 }
    browser.rescanSelection(through: recorded.rescan)
    try await waitFor("the second rescan") { recorded.held.count == 2 }
    let reading = "Reading \(count) files again"
    #expect(browser.status.activityText == reading)

    var first = ScanSummary()
    first.issues = [ScanIssue(kind: .unreadable, path: "/m/a.flac", detail: "gone")]
    recorded.held[0](.success(first))
    try await waitFor("the first report") { !browser.status.rescannedReport.isEmpty }
    #expect(browser.status.activityText == reading)

    var second = ScanSummary()
    second.read = 3
    recorded.held[1](.success(second))
    try await waitFor("the second report") { browser.status.rescannedReport.isEmpty }
    #expect(browser.status.activityText == nil)
    #expect(browser.statusText == "Read 3 files again")
}

/// The issues past the scanner's cap are one row that counts them.
@Test func theUnlistedIssuesAreOneRow() {
    var summary = ScanSummary()
    summary.issues = [ScanIssue(kind: .unreadable, path: "/m/a.flac", detail: "gone")]
    summary.unlistedIssues = 42_000
    let rows = rescannedProblems(summary)
    #expect(rows.count == 2)
    #expect(rows.last?.line == "42,000 files more couldn't be read again, not listed")
    #expect(rescannedSummary(summary) == "Read 0 files again; 42,001 problems")
}

/// A file the rescan couldn't read that its folder's scan reports too is listed once.
@Test func aFileInBothReportsIsListedOnce() {
    let issue = ScanIssue(kind: .unreadable, path: "/m/a.flac", detail: "gone")
    var status = LibraryStatus()
    status.rescannedReport = [Problem(issue)]
    var summary = ScanSummary()
    summary.issues = [issue]
    status.apply(.scanned(folder: "/m", summary))
    #expect(status.problemLines == [issue.description])
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
