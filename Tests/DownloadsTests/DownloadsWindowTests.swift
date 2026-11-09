import AppKit
import Foundation
import Testing

@testable import Downloads
@testable import Fixtures
@testable import Recommender
@testable import Settings
@testable import WindowPlacement

// The window built and filled, its buttons and context menu, the façade without a service, and
// the model's calls that change a job.

private func rows() -> [DownloadRow] {
    [
        job(1) {
            $0.tagging = DownloadJob.Tagging(status: .discrepancy, reasons: ["a track missing"])
        },
        job(2, .downloading) {
            $0.progress = try? replyDecoder.decode(
                DownloadJob.Progress.self,
                from: Data(
                    #"{"files_done": 1, "files_total": 2, "bytes_done": 50, "bytes_total": 100}"#
                        .utf8))
        },
        job(3, .failed) {
            $0.failedStage = .move
            $0.reason = "already in the library"
        },
    ].compactMap { DownloadRow($0, machine: FakeService.machine) }.sorted(by: DownloadRow.listed)
}

@MainActor
@Test func theWindowShowsEachRowItsColumnsAndItsStyle() throws {
    let window = DownloadsWindow()
    window.show(rows(), status: "", canAdd: true)
    #expect(window.table.tableColumns.map(\.title) == DownloadColumn.allCases.map(\.title))
    #expect(window.rows.map(\.id) == [1, 2, 3])
    #expect(window.text(.album, 0) == "Made-Up Artist - Made-Up Album (1999)")
    #expect(window.tooltip(.album, 0) == "Discogs release 4242")
    #expect(window.text(.tagging, 0) == "Discrepancy")
    #expect(window.tooltip(.tagging, 0) == "a track missing")
    #expect(window.color(.tagging, window.rows[0]) == .systemOrange)
    #expect(window.color(.album, window.rows[0]) == .labelColor, "a staged row is opaque")
    #expect(window.text(.candidate, 0).hasPrefix("made-up-peer, "))
    #expect(window.text(.state, 1) == "Downloading, 1 of 2 files")
    #expect(window.color(.album, window.rows[1]) != .labelColor, "a download is dimmed")
    let progress = try #require(
        window.tableView(window.table, viewFor: window.table.tableColumns[3], row: 1)
            as? NSStackView)
    #expect((progress.arrangedSubviews[0] as? NSProgressIndicator)?.doubleValue == 0.5)
    #expect(window.text(.state, 2) == "Failed at move: already in the library")
    #expect(window.color(.state, window.rows[2]) == .systemRed)
    #expect(window.statusLabel.isHidden)
    #expect(window.empty.isHidden)
    window.window?.close()
}

@MainActor
@Test func theButtonsAndTheMenuActOnTheSelectedRowWhenTheyApply() throws {
    let window = DownloadsWindow()
    var acted: [(DownloadAction, Int)] = []
    window.applies = { action, row in action == .openInTagger && row.id == 1 }
    window.act = { acted.append(($0, $1.id)) }
    window.show(rows(), status: "Can't reach the service", canAdd: false)
    #expect(!window.statusLabel.isHidden)
    #expect(!window.addButton.isEnabled)
    let tagger = try #require(window.buttons[.openInTagger])
    #expect(!tagger.isEnabled, "nothing selected")
    window.table.selectRowIndexes([0], byExtendingSelection: false)
    #expect(tagger.isEnabled)
    #expect(window.buttons[.approve]?.isEnabled == false)
    click(tagger)
    #expect(acted.map(\.0) == [.openInTagger])
    #expect(acted.map(\.1) == [1])
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(!tagger.isEnabled)

    let menu = try #require(window.table.menu)
    window.menuNeedsUpdate(menu)
    #expect(menu.items.isEmpty, "no row clicked")
    window.window?.close()
}

@MainActor
@Test func withoutTheServiceTheWindowSaysHowToSetItUp() throws {
    let downloads = Downloads()
    downloads.show()
    let window = try #require(downloads.controller)
    #expect(window.statusLabel.stringValue == Downloads.notSet)
    #expect(window.rows.isEmpty)
    #expect(!window.empty.isHidden)
    #expect(!window.addButton.isEnabled)
    downloads.window?.close()
}

@Test func theStatusLineNamesTheServiceAndWhatThisMacCantDo() {
    let at = Date(timeIntervalSince1970: 1_794_100_000)
    let down = DownloadsModel.status(
        .down("music-recommender at http://192.0.2.7:8080 didn't answer", lastGood: at),
        canAdd: false, problems: ["job 3's report was refused"], formatted: { _ in "10:20" })
    #expect(
        down
            == "Can't reach the service: music-recommender at http://192.0.2.7:8080 didn't answer."
            + " The rows are as they were at 10:20. There's no Discogs catalog on this Mac, so it"
            + " can't queue or tag downloads. job 3's report was refused")
    #expect(
        DownloadsModel.status(.answering, canAdd: true, problems: [], formatted: { _ in "" }) == "")
}

@MainActor
@Test func retryCancelAndCreateShowTheJobTheServiceAnswersWith() async throws {
    let service = FakeService([job(1, .notFound), job(2, .downloading)])
    let model = DownloadsModel(service: service.service, machine: FakeService.machine)
    await model.poll()
    #expect(await model.retry(1, policy: .any) == nil)
    #expect(model.job(1)?.state == .queued)
    #expect(model.job(1)?.formatPolicy == .any)
    #expect(await model.cancel(2) == nil)
    #expect(model.rows.map(\.id) == [1], "a cancelled job isn't listed")
    let snapshot = ReleaseSnapshot(
        releaseID: 77, artist: "Made-Up Artist", title: "Other", year: nil,
        tracklists: [[ReleaseSnapshot.Track(position: "1", title: "One", seconds: 60)]])
    let problems = await model.create([
        (snapshot, .manual(.flac)),
        (snapshot, .manual(.flac)),
    ])
    #expect(service.created.map(\.release) == [77])
    #expect(problems.count == 1, "the second is already active")
    #expect(model.rows.contains { $0.releaseID == 77 })
    service.down = true
    #expect(await model.cancel(1)?.contains("192.0.2.7") == true)
}

@MainActor
@Test func theTableIsReloadedOnlyWhenTheRowsChange() throws {
    let window = DownloadsWindow()
    window.show(rows(), status: "", canAdd: true)
    #expect(window.reloads == 1)
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    window.show(rows(), status: "Can't reach the service", canAdd: false)
    #expect(window.reloads == 1, "the same rows, a new status")
    #expect(window.statusLabel.stringValue == "Can't reach the service")
    #expect(window.table.selectedRow == 1)
    window.show(Array(rows().dropFirst()), status: "", canAdd: true)
    #expect(window.reloads == 2)
    window.window?.close()
}

@MainActor
@Test func everyColumnHasAHeaderWideEnoughToShowIt() throws {
    let window = DownloadsWindow()
    for column in window.table.tableColumns {
        #expect(!column.title.isEmpty, "\(column.identifier.rawValue) has no title")
        // The Album column stretches with the window.
        guard column.resizingMask == .userResizingMask else { continue }
        let header = column.headerCell.attributedStringValue.size().width
        #expect(column.width >= header + 8, "\(column.title) is cut off")
    }
    window.window?.close()
}

@MainActor
@Test func openingWithASelectionOffersFromLibrarySelectionOnceItCanQueue() async throws {
    let service = FakeService([job(1)])
    let (downloads, session) = try await started(service.service) { throw CancellationError() }
    var selection: [Int64] = []
    downloads.selectedTracks = { selection }
    downloads.show(offeringSelection: true)
    #expect(downloads.offeredTracks == nil, "nothing selected")
    downloads.window?.close()

    selection = [7]
    downloads.show()
    #expect(downloads.offeredTracks == nil, "only File > Downloads… offers it")
    downloads.window?.close()

    // No catalog on this Mac: it can't queue, so the offer waits, until the window closes.
    downloads.show(offeringSelection: true)
    #expect(downloads.offeredTracks == [7])
    // The selection changes; the offer keeps the tracks selected when the window opened, and a
    // click on the status item, which offers nothing, leaves it waiting.
    selection = [9]
    downloads.statusItem.clicked()
    #expect(downloads.offeredTracks == [7])
    downloads.window?.close()
    #expect(downloads.offeredTracks == nil)

    // Another sheet on the window drops the offer, so it never comes up after it.
    downloads.show(offeringSelection: true)
    let window = try #require(downloads.window)
    let other = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.beginSheet(other) { _ in }
    #expect(downloads.offeredTracks == nil)
    window.endSheet(other)
    window.close()

    session.canTag = true
    await session.model.poll()
    #expect(session.model.connection == .answering)
    downloads.show(offeringSelection: true)
    #expect(downloads.offeredTracks == nil, "taken at once")
    // The selection's track is in no album of the library, so nothing is shown for it.
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(downloads.window?.attachedSheet == nil)
    downloads.window?.close()
    downloads.stop()
}

@MainActor
@Test func revealInFinderShowsTheStagedFolderWhereTheStagingFolderIsNow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "staging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("job-1", isDirectory: true),
        withIntermediateDirectories: true)
    let service = FakeService([job(1)])
    let (downloads, session) = try await started(service.service) {
        ImportPlaces(stagingRoot: root.path, libraryFolder: "/nowhere", shareRoot: "/")
    }
    var shown: [URL] = []
    downloads.showInFinder = { shown += $0 }
    downloads.reveal(try #require(service.job(1)), session)
    await eventually("the Finder") { !shown.isEmpty }
    #expect(shown.map(\.lastPathComponent) == ["job-1"])
    #expect(shown.first?.deletingLastPathComponent().path == root.path)
    downloads.stop()
}

@MainActor
@Test func revealInFinderRefusesAFolderOutsideTheStagingFolder() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "staging-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("staging", isDirectory: true)
    let outside = base.appendingPathComponent("library", isDirectory: true)
    for folder in [root, outside] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    // A staged folder that's a link out of the staging folder.
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("job-2"), withDestinationURL: outside)
    let service = FakeService([
        job(1) { $0.stagedPath = "../library" }, job(2), job(3) { $0.stagedPath = "/" },
    ])
    let (downloads, session) = try await started(service.service) {
        ImportPlaces(stagingRoot: root.path, libraryFolder: outside.path, shareRoot: "/")
    }
    var shown: [URL] = []
    downloads.showInFinder = { shown += $0 }
    downloads.show()
    let window = try #require(downloads.window)
    for id in [1, 2, 3] {
        downloads.reveal(try #require(service.job(id)), session)
        await eventually("job \(id)'s refusal") { window.attachedSheet != nil }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }
    #expect(shown.isEmpty)
    window.close()
    downloads.stop()
}

@Test func onlyOneFolderNameIsAStagedFolder() {
    for (path, folder) in [
        ("job-42", "job-42"), ("..", nil), (".", nil), ("", nil), ("../x", nil), ("/", nil),
        ("/tmp", nil), ("a/b", nil),
    ] as [(String, String?)] {
        #expect(job(1) { $0.stagedPath = path }.stagedFolder == folder, "\(path)")
    }
    #expect(job(1) { $0.stagedPath = nil }.stagedFolder == nil)
}

@MainActor
@Test func openSlskdOpensThePageTheServiceReports() async throws {
    let service = FakeService([job(1)])
    let (downloads, session) = try await started(service.service) { throw CancellationError() }
    var opened: [URL] = []
    downloads.openPage = { opened.append($0) }
    downloads.show()
    let window = try #require(downloads.controller)
    await eventually("the config's answer") { session.slskdPage != nil }
    #expect(window.slskdButton.isEnabled)
    click(window.slskdButton)
    #expect(opened.map(\.absoluteString) == ["http://192.0.2.7:5030"])
    downloads.window?.close()
    downloads.stop()

    let none = FakeService([job(1)])
    none.slskd = nil
    let (other, _) = try await started(none.service) { throw CancellationError() }
    other.show()
    #expect(other.controller?.slskdButton.isEnabled == false)
    #expect(other.controller?.slskdButton.toolTip == DownloadsWindow.noSlskdHelp)
    other.window?.close()
    other.stop()
}
