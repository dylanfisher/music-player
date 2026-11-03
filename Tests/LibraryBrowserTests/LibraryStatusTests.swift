import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

/// What `count` tracks of `sizeBytes` and `seconds` each add up to.
private func totals(_ count: Int, sizeBytes: Int = 0, seconds: Double = 0) -> TrackTotals {
    TrackTotals(
        count: count, sizeBytes: count * sizeBytes, durationSeconds: Double(count) * seconds)
}

@Test func statusShowsTracksScansAndProblemsApart() {
    var status = LibraryStatus()
    #expect(
        status.summary(list: totals(1), selection: totals(0), shown: .list)
            == "1 track, 0 bytes, 0 seconds")
    #expect(
        status.summary(list: totals(3), selection: totals(0), shown: .list, missingCount: 2)
            == "3 tracks, 0 bytes, 0 seconds · 2 tracks not in the library")
    #expect(status.scanText == nil && status.scanFraction == nil && status.problemsTitle == nil)
    var progress = ScanProgress()
    progress.found = 40
    status.apply(.scanning(folder: "/Volumes/music/library", progress))
    #expect(
        status.summary(list: totals(1200), selection: totals(0), shown: .list)
            == "1,200 tracks, 0 bytes, 0 seconds")
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
    #expect(
        status.summary(list: totals(2), selection: totals(0), shown: .list)
            == "2 tracks, 0 bytes, 0 seconds")
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
    #expect(
        status.summary(list: totals(0), selection: totals(0), shown: .list, playCount: 1_000_000)
            == "1,000,000 plays")
    status.notices = ["the earlier stats were discarded"]
    #expect(status.hasProblems)
    #expect(
        status.summary(list: totals(2), selection: totals(0), shown: .list)
            == "2 tracks, 0 bytes, 0 seconds · earlier play counts and playlists discarded")
    // It counts no file or folder, but has a list to open.
    #expect(status.problemsTitle == "Show Problems")
    #expect(status.problemLines == ["the earlier stats were discarded"])
}

@Test func aWindowReportRoundTripsAndRejectsUnknownKeys() throws {
    let report = WindowReport(
        launchSeconds: 0.4, loadedMB: 80, scrolledMB: 95, scrollStepsMs: [3.5, 4], rows: 10,
        artImages: 2, artFailures: 0)
    #expect(try WindowReport.decode(try JSONEncoder().encode(report)) == report)
    #expect(throws: DecodingError.self) {
        try WindowReport.decode(
            Data(
                (#"{"launchSeconds": 1, "loadedMB": 1, "scrolledMB": 1, "scrollStepsMs": [1],"#
                    + #" "rows": 1,"#
                    + #" "artImages": 1, "artFailures": 0, "extra": 1}"#).utf8))
    }
}

@Test func aHealthCheckCountsWhatTheTableCantListAndListsIt() {
    var status = LibraryStatus()
    status.healthLines = ["/M/bad.flac: failure malformed: no header"]
    status.healthOtherCount = 1
    #expect(
        status.summary(list: totals(2), selection: totals(0), shown: .list)
            == "2 tracks, 0 bytes, 0 seconds · 1 more item with no track to list")
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

@Test func theTotalsAddSizesAndLengthsAsSwinsianWritesThem() {
    #expect(
        totals(43_400, sizeBytes: 25_931_000, seconds: 369.7457603686636).text()
            == "43,400 tracks, 1048.1 GiB, 185 days 17 hours 29 minutes 26 seconds")
    #expect(
        totals(1, sizeBytes: 318_242_406, seconds: 3722).text(selected: true)
            == "1 track selected, 303.5 MiB, 1 hour 2 minutes 2 seconds")
    #expect(binarySize(1023) == "1,023 bytes")
    #expect(binarySize(1536) == "1.5 KiB")
    #expect(binarySize(1_048_575) == "1.0 MiB")
    #expect(spokenDuration(0.4) == "0 seconds")
    #expect(spokenDuration(86_400) == "1 day")
}

@Test func theStatusShowsTheTotalsAClickChose() {
    let status = LibraryStatus()
    let list = totals(2, sizeBytes: 1024, seconds: 60)
    let one = totals(1, sizeBytes: 1024, seconds: 60)
    let none = totals(0)
    let listText = "2 tracks, 2.0 KiB, 2 minutes"
    let oneText = "1 track selected, 1.0 KiB, 1 minute"
    #expect(
        status.summary(list: list, selection: one, shown: .listAndSelection)
            == "\(listText) (\(oneText))")
    #expect(status.summary(list: list, selection: one, shown: .list) == listText)
    #expect(status.summary(list: list, selection: one, shown: .selection) == oneText)
    // With nothing selected, every choice shows the list's.
    for shown in StatusTotals.allCases {
        #expect(status.summary(list: list, selection: none, shown: shown) == listText)
    }
    #expect(StatusTotals.listAndSelection.next.next.next == .listAndSelection)
    #expect(StatusTotals.listAndSelection.next == .list)
    #expect(StatusTotals.list.next == .selection)
}
