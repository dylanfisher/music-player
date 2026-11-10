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

/// Each setting's default, as the app reads them.
private func formats(_ schema: AppSettings) -> TotalsFormats {
    TotalsFormats(
        nothingSelected: schema.totalsFormat.defaultValue,
        listAndSelection: schema.totalsListAndSelectionFormat.defaultValue,
        list: schema.totalsListFormat.defaultValue,
        selection: schema.totalsSelectionFormat.defaultValue)
}

/// Every total in one template, for the list and for the selection.
private let everyToken = TotalsTemplate(
    "{tracks}|{size}|{duration}|{albums}|{selectedTracks}|{selectedSize}|{selectedDuration}"
        + "|{selectedAlbums}|{missing}")

private func formats(all template: TotalsTemplate) -> TotalsFormats {
    TotalsFormats(
        nothingSelected: template, listAndSelection: template, list: template,
        selection: template)
}

/// A tag save shows beside the scans, its bar filling while nothing scans (ADR 0108).
@Test func aTagSaveShowsBesideTheScans() {
    var status = LibraryStatus()
    #expect(status.activityText == nil && status.activityFraction == nil)
    status.savingText = "Saving tags: 3 of 20"
    status.savingFraction = 0.4
    #expect(status.activityText == "Saving tags: 3 of 20")
    #expect(status.activityFraction == 0.4)
    var progress = ScanProgress()
    progress.found = 40
    status.apply(.scanning(folder: "/Volumes/music/library", progress))
    #expect(status.activityText == "Scanning library: 40 files checked · Saving tags: 3 of 20")
    #expect(status.activityFraction == nil, "the scan is still listing folders")
    status.apply(.scanned(folder: "/Volumes/music/library", ScanSummary()))
    status.savingText = nil
    #expect(status.activityText == nil && status.activityFraction == nil)
}

/// Analyze Library shows after the scans and a save, its bar filling while neither runs, and
/// says a scan is under way while one is.
@Test func libraryAnalysisShowsAfterTheScansAndASave() {
    var status = LibraryStatus()
    status.analysisText = "Analyzing library: 40 of 1,200"
    status.analysisFraction = 0.25
    #expect(status.activityText == "Analyzing library: 40 of 1,200")
    #expect(status.activityFraction == 0.25 && !status.isScanning)
    status.savingText = "Saving tags: 3 of 20"
    status.savingFraction = 0.4
    #expect(status.activityText == "Saving tags: 3 of 20 · Analyzing library: 40 of 1,200")
    #expect(status.activityFraction == 0.4)
    status.apply(.scanning(folder: "/Volumes/music/library", ScanProgress()))
    #expect(status.isScanning)
    status.apply(.scanFailed(folder: "/Volumes/music/library", reason: "gone"))
    #expect(!status.isScanning)
    // A retry that fails the same way ends the same way, as the watcher reports each one.
    status.apply(.scanning(folder: "/Volumes/music/library", ScanProgress()))
    status.apply(.scanFailed(folder: "/Volumes/music/library", reason: "gone"))
    #expect(!status.isScanning && status.scanText == nil)
}

/// A scan Pause Scan holds says so, and Analyze Library doesn't wait for it, since it reads
/// nothing; Resume Scan or its end clears the pause (ADR 0119).
@Test func aPausedScanSaysSoAndAnalysisDoesntWaitForIt() {
    var status = LibraryStatus()
    var progress = ScanProgress()
    progress.stage = .reading
    progress.read = 300
    progress.toRead = 1200
    status.apply(.scanning(folder: "/Volumes/music/library", progress))
    status.savingText = "Saving tags: 3 of 20"
    status.apply(.scanPaused(folder: "/Volumes/music/library", true))
    #expect(status.scanText == "Scan paused: library: 300 of 1,200 read")
    #expect(
        status.scanAndSaveText == "Scan paused: library: 300 of 1,200 read · Saving tags: 3 of 20")
    #expect(status.scanIsPaused && !status.isScanning)
    status.apply(.scanPaused(folder: "/Volumes/music/library", false))
    #expect(status.scanText == "Scanning library: 300 of 1,200 read" && status.isScanning)

    // Paused before its first progress, it shows; its end clears the pause.
    status.apply(.scanned(folder: "/Volumes/music/library", ScanSummary()))
    status.apply(.scanPaused(folder: "/Volumes/music/other", true))
    #expect(status.scanText == "Scan paused: other: 0 files checked")
    // Its bar stands still, empty, rather than moving on its own.
    #expect(status.scanFraction == 0 && status.activityFraction == 0)
    status.apply(.scanFailed(folder: "/Volumes/music/other", reason: "gone"))
    #expect(!status.scanIsPaused && status.scanText == nil)
}

/// After a rebuild of the index, each folder's scan says it's the rebuild until one of its scans
/// ends; a stopped scan is still the rebuild's when it starts again (ADR 0136).
@Test func aScanAfterARebuildSaysItsTheRebuild() {
    var status = LibraryStatus()
    status.rebuildingIndex = true
    var progress = ScanProgress()
    progress.read = 300
    progress.toRead = 1200
    status.apply(.scanning(folder: "/Volumes/music/Music", progress))
    #expect(status.scanText == "Rebuilding the index: Music: 300 of 1,200 read")
    status.apply(.scanStopped(folder: "/Volumes/music/Music"))
    status.apply(.scanning(folder: "/Volumes/music/Music", progress))
    status.apply(.scanning(folder: "/Volumes/music/Other", progress))
    status.apply(.scanned(folder: "/Volumes/music/Other", ScanSummary()))
    status.apply(.scanning(folder: "/Volumes/music/Other", progress))
    #expect(
        status.scanText
            == "Rebuilding the index: Music: 300 of 1,200 read · Scanning Other: 300 of 1,200 read")
    status.apply(.scanned(folder: "/Volumes/music/Music", ScanSummary()))
    status.apply(.scanning(folder: "/Volumes/music/Music", progress))
    #expect(
        status.scanText == "Scanning Music: 300 of 1,200 read · Other: 300 of 1,200 read")

    // A scan that failed has ended too: the next is a plain one.
    status.apply(.scanning(folder: "/Volumes/music/Failing", progress))
    status.apply(.scanFailed(folder: "/Volumes/music/Failing", reason: "gone"))
    status.apply(.scanning(folder: "/Volumes/music/Failing", progress))
    #expect(status.scanText?.contains("Rebuilding") == false, "\(status.scanText ?? "")")
}

/// A scan the watcher's stop cancelled, as when a folder is removed, leaves the status bar, and
/// a pause of it with it, so no dead Resume stays.
@Test func aStoppedScanLeavesTheStatusBarWithItsPause() {
    var status = LibraryStatus()
    status.apply(.scanning(folder: "/Volumes/music/library", ScanProgress()))
    status.apply(.scanPaused(folder: "/Volumes/music/library", true))
    status.apply(.scanStopped(folder: "/Volumes/music/library"))
    #expect(status.scanText == nil && !status.scanIsPaused && !status.isScanning)
    #expect(status.failures.isEmpty)
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

@Test func theTimelineCountsPlaysAndADiscardShowsAsAProblemNotInTheTotals() {
    var status = LibraryStatus()
    #expect(
        status.summary(list: totals(0), selection: totals(0), shown: .list, playCount: 1_000_000)
            == "1,000,000 plays")
    status.notices = ["the earlier stats were discarded"]
    #expect(status.hasProblems)
    #expect(
        status.summary(list: totals(2), selection: totals(0), shown: .list)
            == "2 tracks, 0 bytes, 0 seconds")
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

@Test func aScrollReportRoundTripsAndRejectsUnknownKeys() throws {
    for lastCoverMs in [120, nil] as [Double?] {
        let report = ScrollReport(
            framesMs: [2.5, 3], refreshFramesMs: [3], lastCoverMs: lastCoverMs, artReads: 4,
            pageCoversMs: [130, 95.5])
        #expect(
            try JSONDecoder().decode(ScrollReport.self, from: try JSONEncoder().encode(report))
                == report)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            ScrollReport.self,
            from: Data(
                (#"{"framesMs": [1], "refreshFramesMs": [], "artReads": 1, "pageCoversMs": [],"#
                    + #" "extra": 1}"#).utf8))
    }
}

@Test func aHealthCheckCountsWhatTheTableCantListAndListsIt() {
    var status = LibraryStatus()
    status.healthProblems = [Problem("/M/bad.flac: failure malformed: no header")]
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
    let status = LibraryStatus()
    let list = totals(43_400, sizeBytes: 25_931_000, seconds: 369.7457603686636)
    #expect(
        status.summary(list: list, selection: totals(0), shown: .listAndSelection)
            == "43,400 tracks, 1048.1 GiB, 185 days 17 hours 29 minutes 26 seconds")
    #expect(
        status.summary(
            list: list, selection: totals(1, sizeBytes: 318_242_406, seconds: 3722),
            shown: .selection)
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
    // The defaults are the bar's text as it was before its templates.
    #expect(TotalsFormats.defaults == formats(AppSettings()))
    #expect(StatusTotals.listAndSelection.next.next.next == .listAndSelection)
    #expect(StatusTotals.listAndSelection.next == .list)
    #expect(StatusTotals.list.next == .selection)
}

/// Each token's value: the list's totals, the selection's, and the playlist's missing count.
@Test func eachTotalFillsItsToken() {
    let status = LibraryStatus()
    var list = totals(1200, sizeBytes: 4_473_924, seconds: 216)
    list.albumCount = 98
    var selected = totals(3, sizeBytes: 3_565_158, seconds: 240)
    selected.albumCount = 1
    #expect(
        status.summary(
            list: list, selection: selected, shown: .listAndSelection,
            formats: formats(all: everyToken), missingCount: 2)
            == "1,200 tracks|5.0 GiB|3 days|98 albums|3 tracks|10.2 MiB|12 minutes|1 album"
            + "|2 tracks")
}

/// With nothing selected the selection's tokens are empty, so the text that goes with them
/// goes too, as an empty field's does in the title line.
@Test func theSelectionsTokensAreEmptyWithNothingSelected() {
    let status = LibraryStatus()
    let template = TotalsTemplate(
        "{tracks} on {albums} ({selectedTracks} selected on {selectedAlbums})")
    let list = totals(2, sizeBytes: 1024, seconds: 60)
    var formats = formats(all: template)
    #expect(
        status.summary(list: list, selection: totals(0), shown: .list, formats: formats)
            == "2 tracks on 0 albums")
    formats.nothingSelected = TotalsTemplate("{selectedTracks}")
    #expect(status.summary(list: list, selection: totals(0), shown: .list, formats: formats) == "")
}

/// A template that places the missing count shows it there, and the bar doesn't add it again;
/// without the token the count is added after the totals, as before.
@Test func theMissingCountGoesWhereTheTemplatePutsIt() {
    let status = LibraryStatus()
    let list = totals(3)
    var formats = TotalsFormats.defaults
    formats.nothingSelected = TotalsTemplate("{tracks} ({missing} missing)")
    #expect(
        status.summary(
            list: list, selection: totals(0), shown: .list, formats: formats, missingCount: 2)
            == "3 tracks (2 tracks missing)")
    #expect(
        status.summary(list: list, selection: totals(0), shown: .list, formats: formats)
            == "3 tracks")
    #expect(
        status.summary(
            list: list, selection: totals(0), shown: .list, missingCount: 2)
            == "3 tracks, 0 bytes, 0 seconds · 2 tracks not in the library")
}

/// Each choice a click cycles through has its own template, and the nothing-selected line
/// has one of its own, whichever choice is shown.
@Test func eachChoiceHasItsOwnTemplate() {
    let status = LibraryStatus()
    let formats = TotalsFormats(
        nothingSelected: TotalsTemplate("none: {tracks}"),
        listAndSelection: TotalsTemplate("both: {tracks} {selectedTracks}"),
        list: TotalsTemplate("list: {tracks}"),
        selection: TotalsTemplate("selection: {selectedTracks}"))
    let list = totals(2)
    let one = totals(1)
    func summary(_ shown: StatusTotals, _ selection: TrackTotals) -> String {
        status.summary(list: list, selection: selection, shown: shown, formats: formats)
    }
    #expect(summary(.listAndSelection, one) == "both: 2 tracks 1 track")
    #expect(summary(.list, one) == "list: 2 tracks")
    #expect(summary(.selection, one) == "selection: 1 track")
    for shown in StatusTotals.allCases { #expect(summary(shown, totals(0)) == "none: 2 tracks") }
    // The timeline counts plays, whatever the templates say.
    #expect(
        status.summary(
            list: list, selection: one, shown: .list, formats: formats, playCount: 5)
            == "5 plays")
}
