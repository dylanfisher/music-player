import Foundation
import Testing

@testable import Library
@testable import LibraryBrowser

@Test func statusShowsTracksScansAndProblems() {
    var status = LibraryStatus()
    #expect(status.text(trackCount: 1) == "1 track")
    var progress = ScanProgress()
    progress.found = 40
    status.apply(.scanning(folder: "/Volumes/music/library", progress))
    #expect(status.text(trackCount: 1200) == "1,200 tracks · scanning library: 40 files checked")
    progress.toRead = 1200
    progress.read = 300
    status.apply(.scanning(folder: "/Volumes/music/library", progress))
    #expect(status.text(trackCount: 1200).hasSuffix("scanning library: 300 of 1,200 read"))

    var summary = ScanSummary()
    summary.issues = [
        ScanIssue(kind: .rootVanished, path: "/Volumes/music/library", detail: "gone")
    ]
    status.apply(.scanned(folder: "/Volumes/music/library", summary))
    status.fileIssueCount = 3
    #expect(status.text(trackCount: 2) == "2 tracks · 3 files and 1 folder with problems")
    #expect(status.hasProblems)
    #expect(status.folderLines.count == 1)

    status.apply(.scanned(folder: "/Volumes/music/library", ScanSummary()))
    status.fileIssueCount = 0
    #expect(!status.hasProblems)
    status.apply(.scanFailed(folder: "/Music", reason: "disk I/O error"))
    #expect(status.folderLines == ["/Music: the scan failed: disk I/O error"])
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
