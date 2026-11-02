import Foundation
import Testing

@testable import Library
@testable import LibraryBrowser

@Test func statusShowsTracksScansAndProblemsApart() {
    var status = LibraryStatus()
    #expect(status.summary(trackCount: 1) == "1 track")
    #expect(
        status.summary(trackCount: 3, missingCount: 2) == "3 tracks · 2 tracks not in the library")
    #expect(status.scanText == nil && status.scanFraction == nil && status.problemsTitle == nil)
    var progress = ScanProgress()
    progress.found = 40
    status.apply(.scanning(folder: "/Volumes/music/library", progress))
    #expect(status.summary(trackCount: 1200) == "1,200 tracks")
    #expect(status.scanText == "Scanning library: 40 files checked")
    // Still listing folders, so how much there is to read isn't known yet.
    #expect(status.scanFraction == nil)
    progress.toRead = 1200
    progress.read = 300
    status.apply(.scanning(folder: "/Volumes/music/library", progress))
    #expect(status.scanText == "Scanning library: 300 of 1,200 read")
    #expect(status.scanFraction == nil)
    progress.stage = .reading
    status.apply(.scanning(folder: "/Volumes/music/library", progress))
    #expect(status.scanFraction == 0.25)

    var summary = ScanSummary()
    summary.issues = [
        ScanIssue(kind: .rootVanished, path: "/Volumes/music/library", detail: "gone")
    ]
    status.apply(.scanned(folder: "/Volumes/music/library", summary))
    #expect(status.scanText == nil && status.scanFraction == nil)
    status.fileIssueCount = 3
    #expect(status.summary(trackCount: 2) == "2 tracks")
    #expect(status.problemsTitle == "3 files and 1 folder with problems")
    #expect(status.hasProblems)
    #expect(status.problemLines.count == 1)

    status.apply(.scanned(folder: "/Volumes/music/library", ScanSummary()))
    status.fileIssueCount = 0
    #expect(!status.hasProblems)
    #expect(status.problemsTitle == nil)
    status.apply(.scanFailed(folder: "/Music", reason: "disk I/O error"))
    #expect(status.problemLines == ["/Music: the scan failed: disk I/O error"])
}

@Test func theTimelineCountsPlaysAndADiscardShowsAsAProblem() {
    var status = LibraryStatus()
    #expect(status.summary(trackCount: 0, playCount: 1_000_000) == "1,000,000 plays")
    status.notices = ["the earlier stats were discarded"]
    #expect(status.hasProblems)
    #expect(
        status.summary(trackCount: 2) == "2 tracks · earlier play counts and playlists discarded")
    // It counts no file or folder, but has a list to open.
    #expect(status.problemsTitle == "Show Problems")
    #expect(status.problemLines == ["the earlier stats were discarded"])
}

@Test func aWindowReportRoundTripsAndRejectsUnknownKeys() throws {
    let report = WindowReport(
        launchSeconds: 0.4, loadedMB: 80, scrolledMB: 95, rows: 10, artImages: 2, artFailures: 0)
    #expect(try WindowReport.decode(try JSONEncoder().encode(report)) == report)
    #expect(throws: DecodingError.self) {
        try WindowReport.decode(
            Data(
                (#"{"launchSeconds": 1, "loadedMB": 1, "scrolledMB": 1, "rows": 1,"#
                    + #" "artImages": 1, "artFailures": 0, "extra": 1}"#).utf8))
    }
}

@Test func aHealthCheckCountsWhatTheTableCantListAndListsIt() {
    var status = LibraryStatus()
    status.healthLines = ["/M/bad.flac: failure malformed: no header"]
    status.healthOtherCount = 1
    #expect(status.summary(trackCount: 2) == "2 tracks · 1 more item with no track to list")
    #expect(status.hasProblems)
    #expect(status.problemLines == ["/M/bad.flac: failure malformed: no header"])
}

@Test func aSyncsProblemsShowUntilTheNextSync() {
    var status = LibraryStatus()
    var report = SyncReport()
    report.problems = ["/Volumes/music/sync/ab.log: line 3 has no \"seq\""]
    status.apply(.synced(report))
    #expect(status.problemsTitle == "The sync with problems")
    #expect(status.problemLines == report.problems)
    status.apply(.syncFailed(reason: "can't open /Volumes/music/sync"))
    #expect(status.problemLines == ["the sync failed: can't open /Volumes/music/sync"])
    status.apply(.synced(SyncReport()))
    #expect(!status.hasProblems)
}
