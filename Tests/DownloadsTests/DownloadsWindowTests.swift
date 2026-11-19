import AppKit
import Foundation
import Testing

@testable import Downloads
@testable import Fixtures
@testable import Library
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
    #expect(window.text(.user, 0) == "made-up-peer")
    #expect(!window.text(.candidate, 0).contains("made-up-peer"))
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
    var acted: [(DownloadAction, [Int])] = []
    window.applies = { action, row in action == .openInTagger && row.id == 1 }
    window.act = { acted.append(($0, $1.map(\.id))) }
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
    #expect(acted.map(\.1) == [[1]])
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(!tagger.isEnabled)

    let menu = try #require(window.table.menu)
    window.menuNeedsUpdate(menu)
    #expect(menu.items.isEmpty, "no row clicked")
    window.window?.close()
}

@MainActor
@Test func onSeveralRowsEachActionActsOnThoseItAppliesToAndTheMenuOnTheClickedOnes() throws {
    let window = DownloadsWindow()
    var acted: [(DownloadAction, [Int])] = []
    // Retry applies to 1 and 3, Cancel to 2, Open in Tagger to 1 and 3, nothing to Approve.
    window.applies = { action, row in
        switch action {
        case .retry, .openInTagger: row.id != 2
        case .cancel: row.id == 2
        default: false
        }
    }
    window.act = { acted.append(($0, $1.map(\.id))) }
    window.show(rows(), status: "", canAdd: true)
    #expect(window.table.allowsMultipleSelection)
    window.table.selectAll(nil)
    #expect(window.selectedRows.map(\.id) == [1, 2, 3], "⌘A")
    #expect(window.buttons[.retry]?.isEnabled == true)
    #expect(window.buttons[.cancel]?.isEnabled == true)
    #expect(window.buttons[.approve]?.isEnabled == false)
    for action in [DownloadAction.retry, .cancel, .openInTagger] {
        click(try #require(window.buttons[action]))
    }
    #expect(acted.map(\.0) == [.retry, .cancel, .openInTagger])
    #expect(acted.map(\.1) == [[1, 3], [2], [1]], "a review opens on the first")

    window.table.selectRowIndexes([0, 1], byExtendingSelection: false)
    #expect(window.buttons[.cancel]?.isEnabled == true, "it applies to one of them")
    acted = []
    let menu = try #require(window.table.menu)
    for clicked in [1, 2] {
        window.fill(menu, clicked: clicked)
        let retry = try #require(menu.items.first { $0.title == DownloadAction.retry.title })
        #expect(retry.isEnabled)
        menu.performActionForItem(at: menu.index(of: retry))
    }
    #expect(acted.map(\.1) == [[1], [3]], "the selection, then a row outside it alone")
    window.window?.close()
}

@MainActor
@Test func aReviewFromTheMenuOpensOnTheClickedRowInsideASelection() throws {
    let window = DownloadsWindow()
    var acted: [[Int]] = []
    window.applies = { action, _ in action == .openInTagger }
    window.act = { acted.append($1.map(\.id)) }
    window.show(rows(), status: "", canAdd: true)
    window.table.selectRowIndexes([0, 1], byExtendingSelection: false)
    let menu = try #require(window.table.menu)
    window.fill(menu, clicked: 1)
    let tagger = try #require(
        menu.items.first { $0.title == DownloadAction.openInTagger.title })
    menu.performActionForItem(at: menu.index(of: tagger))
    click(try #require(window.buttons[.openInTagger]))
    #expect(acted == [[2], [1]], "the clicked row, then the button's first")
    window.window?.close()
}

@MainActor
@Test func severalJobsAreActedOnAsTheyAreOnceTheQuestionIsAnswered() async throws {
    let fake = FakeService([
        job(1, .notFound),
        job(3) { $0.tagging = DownloadJob.Tagging(status: .discrepancy, reasons: ["x"]) },
    ])
    let (downloads, session) = try await started(fake.service) { throw CancellationError() }
    var yes: (() -> Void)?
    downloads.answer = { yes = $1 }
    downloads.show()
    let window = try #require(downloads.controller)
    await eventually("the first poll") { window.rows.count == 2 }
    window.table.selectAll(nil)
    click(try #require(window.buttons[.retry]))
    let answer = try #require(yes)
    // While the question is up, job 1 is imported and job 3's copy fails its search.
    fake.put(job(1, .imported))
    fake.put(
        job(3, .failed) {
            $0.failedStage = .search
            $0.tagging = DownloadJob.Tagging(status: .discrepancy, reasons: ["x"])
        })
    await session.model.poll()
    answer()
    await eventually("job 3 retried") { fake.job(3)?.state == .queued }
    #expect(fake.requeued.isEmpty, "retried as it is now, not requeued as it was")
    #expect(fake.job(1)?.state == .imported, "Retry no longer applies to it")
    downloads.window?.close()
    downloads.stop()
}

@MainActor
@Test func aMissingStagingFolderIsSaidWithTheFoldersRefusedBefore() async throws {
    let service = FakeService([
        job(1) { $0.stagedPath = "../library" }, job(2) { $0.stagedPath = "job-2" },
    ])
    let (downloads, session) = try await started(service.service) {
        throw CancellationError()
    }
    downloads.show()
    let window = try #require(downloads.window)
    downloads.reveal([try #require(service.job(1)), try #require(service.job(2))], session)
    await eventually("the alert") { window.attachedSheet != nil }
    let texts = labels(in: window.attachedSheet?.contentView)
    #expect(texts.contains(Downloads.noStagingFolder))
    #expect(texts.contains { $0.contains(DownloadJob.notOneFolder("../library")) })
    if let sheet = window.attachedSheet { window.endSheet(sheet) }
    window.close()
    downloads.stop()
}

/// Every label's text under `view`.
@MainActor
private func labels(in view: NSView?) -> [String] {
    guard let view else { return [] }
    return ((view as? NSTextField).map { [$0.stringValue] } ?? [])
        + view.subviews.flatMap { labels(in: $0) }
}

@MainActor
@Test func aRefreshKeepsEverySelectedJobSelected() {
    let window = DownloadsWindow()
    window.show(rows(), status: "", canAdd: true)
    window.table.selectRowIndexes([0, 2], byExtendingSelection: false)
    var reordered = rows()
    reordered.swapAt(0, 1)
    reordered.remove(at: 2)
    window.show(reordered, status: "", canAdd: true)
    #expect(window.rows.map(\.id) == [2, 1])
    #expect(window.selectedRows.map(\.id) == [1], "job 3 is gone")
    window.window?.close()
}

@MainActor
@Test func cancellingOrRetryingSeveralAsksOnceAndSendsEach() async throws {
    let fake = FakeService([
        job(1, .notFound), job(2, .downloading),
        job(3) { $0.tagging = DownloadJob.Tagging(status: .discrepancy, reasons: ["x"]) },
    ])
    let (downloads, session) = try await started(fake.service) { throw CancellationError() }
    var asked: [String] = []
    downloads.answer = {
        asked.append($0)
        $1()
    }
    downloads.show()
    let window = try #require(downloads.controller)
    await eventually("the first poll") { window.rows.count == 3 }
    let row = { (id: Int) in window.rows.firstIndex { $0.id == id }! }
    window.table.selectRowIndexes([row(1), row(3)], byExtendingSelection: false)
    click(try #require(window.buttons[.retry]))
    #expect(asked == ["Retry 2 downloads?"])
    await eventually("both sent") { fake.requeued == [3] && fake.job(1)?.state == .queued }
    #expect(fake.job(1)?.formatPolicy == .flac, "the format it asked for")

    await eventually("the retried rows") { session.model.job(1)?.state == .queued }
    window.table.selectRowIndexes(
        IndexSet(window.rows.indices), byExtendingSelection: false)
    click(try #require(window.buttons[.cancel]))
    #expect(asked.last == "Cancel \(window.selectedRows.count) downloads?")
    #expect(asked.count == 2)
    await eventually("every one cancelled") {
        [1, 2].allSatisfy { fake.job($0)?.state == .cancelled }
    }
    downloads.window?.close()
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

/// Types `text` in the window's search field.
@MainActor
private func type(_ text: String, in window: DownloadsWindow) {
    window.search.stringValue = text
    window.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: window.search))
}

@MainActor
@Test func theSearchFieldFiltersTheRowsAndAShowKeepsIt() throws {
    let window = DownloadsWindow()
    window.show(rows(), status: "", canAdd: true)
    window.table.selectRowIndexes([2], byExtendingSelection: false)
    type("move", in: window)
    #expect(window.rows.map(\.id) == [3])
    #expect(window.table.selectedRow == 0, "the selected job stays selected")
    #expect(window.empty.isHidden)
    window.show(rows(), status: "", canAdd: true)
    #expect(window.rows.map(\.id) == [3], "the rows of a poll are filtered too")
    type("zzz", in: window)
    #expect(window.rows.isEmpty)
    #expect(!window.empty.isHidden)
    #expect(window.empty.stringValue == DownloadsWindow.noneMatch)
    type("", in: window)
    #expect(window.rows.map(\.id) == [1, 2, 3])
    type("move", in: window)
    // The cancel button: the field emptied and its action sent, with no text change.
    window.search.stringValue = ""
    window.search.sendAction(window.search.action, to: window.search.target)
    #expect(window.rows.map(\.id) == [1, 2, 3], "cleared by the cancel button")
    window.show([], status: "", canAdd: true)
    #expect(window.empty.stringValue == DownloadsWindow.noDownloads)
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
    downloads.show(offeringSelection: true)
    #expect(downloads.offeredTracks == nil, "one track isn't an album to offer")
    downloads.window?.close()

    selection = [7, 8]
    downloads.show()
    #expect(downloads.offeredTracks == nil, "only File > Downloads… offers it")
    downloads.window?.close()

    // No catalog on this Mac: it can't queue, so the offer waits, until the window closes.
    downloads.show(offeringSelection: true)
    #expect(downloads.offeredTracks == [7, 8])
    // The selection changes; the offer keeps the tracks selected when the window opened, and a
    // click on the status item, which offers nothing, leaves it waiting.
    selection = [9, 10]
    downloads.statusItem.clicked()
    #expect(downloads.offeredTracks == [7, 8])
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
    for folder in ["job-1", "job-2"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(folder, isDirectory: true),
            withIntermediateDirectories: true)
    }
    let service = FakeService([job(1), job(2) { $0.stagedPath = "job-2" }])
    let (downloads, session) = try await started(service.service) {
        ImportPlaces(stagingRoot: root.path, libraryFolder: "/nowhere", shareRoot: "/")
    }
    var shown: [[URL]] = []
    downloads.showInFinder = { shown.append($0) }
    downloads.reveal([try #require(service.job(1))], session)
    await eventually("the Finder") { !shown.isEmpty }
    #expect(shown.map { $0.map(\.lastPathComponent) } == [["job-1"]])
    #expect(shown.first?.first?.deletingLastPathComponent().path == root.path)
    downloads.reveal([try #require(service.job(1)), try #require(service.job(2))], session)
    await eventually("the Finder again") { shown.count == 2 }
    #expect(shown.last?.map(\.lastPathComponent) == ["job-1", "job-2"], "together")
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
        downloads.reveal([try #require(service.job(id))], session)
        await eventually("job \(id)'s refusal") { window.attachedSheet != nil }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }
    #expect(shown.isEmpty)
    window.close()
    downloads.stop()
}

/// Show in All Music finds the album by the release its files carry, and says in the status
/// line when the library has none.
@MainActor
@Test func showInAllMusicShowsTheAlbumOfTheReleaseOrSaysItIsntThere() async throws {
    let service = FakeService([
        job(1, .imported), job(2, .imported) { $0.release.releaseID = 5 },
        job(3, .downloading) {
            $0.release.releaseID = 6
            $0.upgrade = DownloadJob.Upgrade(
                currentQuality: "MP3 320 kbps", oldPaths: ["library/a/01.mp3"])
        },
    ])
    let (downloads, session) = try await started(
        service.service,
        prepare: { try $0.recordTaggedRelease(job: 1, queued: 4242, folder: "job-1", release: 77) },
        places: { ImportPlaces(stagingRoot: "/nowhere", libraryFolder: "/nowhere", shareRoot: "/") }
    )
    await eventually("the release tagged as") { session.model.taggedAs(1) == 77 }
    var asked: [Int] = []
    downloads.albumOfRelease = { _, release in
        await MainActor.run { asked.append(release) }
        return release == 5 ? nil : Int64(release * 10)
    }
    var shown: [Int64] = []
    downloads.showInAllMusic = { shown.append($0) }
    downloads.show()
    let window = try #require(downloads.controller)
    downloads.showInLibrary(try #require(session.model.job(1)), session)
    await eventually("the album tagged as") { shown == [770] }
    downloads.showInLibrary(try #require(session.model.job(2)), session)
    await eventually("the status line") {
        window.statusLabel.stringValue.contains(LibraryIndex.releaseNotInLibrary(5))
    }
    #expect(shown == [770], "nothing shown")
    window.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(!window.statusLabel.stringValue.contains(LibraryIndex.releaseNotInLibrary(5)))
    downloads.showInLibrary(try #require(session.model.job(2)), session)
    await eventually("said again") {
        window.statusLabel.stringValue.contains(LibraryIndex.releaseNotInLibrary(5))
    }
    downloads.showInLibrary(try #require(session.model.job(3)), session)
    #expect(
        !window.statusLabel.stringValue.contains(LibraryIndex.releaseNotInLibrary(5)),
        "gone as the next lookup starts")
    await eventually("the album the upgrade replaces") { shown == [770, 60] }
    #expect(asked == [77, 5, 5, 6])
    downloads.showInLibrary(try #require(session.model.job(2)), session)
    await eventually("said once more") { downloads.notShown != nil }
    downloads.stop()
    #expect(downloads.notShown == nil, "gone with the session")
    window.window?.close()
}

/// The toolbar's buttons all show at the window's smallest width.
@MainActor
@Test func theToolbarFitsTheSmallestWindow() throws {
    let window = DownloadsWindow()
    let content = try #require(window.window?.contentView)
    let smallest = try #require(window.window?.minSize.width)
    #expect(content.fittingSize.width <= smallest)
    window.window?.close()
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

@MainActor
@Test func theAlbumsTooltipNamesTheReleaseTheFilesAreTaggedAs() throws {
    let window = DownloadsWindow()
    let row = try #require(DownloadRow(job(1), machine: FakeService.machine, taggedAs: 5151))
    window.show([row], status: "", canAdd: true)
    #expect(window.tooltip(.album, 0) == "Discogs release 4242; tagged as Discogs release 5151")
    #expect(window.text(.tagging, 0) == "Pending, another release")
    window.window?.close()
}

/// Approve Safe Matches Automatically is a box above the toolbar that shows the setting and
/// reports a click, and the façade saves it (ADR 0193).
@MainActor
@Test func theAutoApproveBoxShowsTheSettingAndReportsAClick() throws {
    let downloads = Downloads()
    var chosen: [Bool] = []
    downloads.autoApproveChosen = { on in
        chosen.append(on)
        downloads.autoApprove = on
    }
    downloads.show()
    let window = try #require(downloads.controller)
    let box = window.autoApproveBox
    #expect(box.state == .off)
    #expect(box.title == AppSettings().autoApproveSafeMatches.title)
    click(box)
    #expect(chosen == [true])
    #expect(box.state == .on)
    downloads.autoApprove = false
    #expect(box.state == .off)
    window.window?.close()
}

/// Upgrade to FLAC Automatically beside it does the same (ADR 0200).
@MainActor
@Test func theAutoUpgradeBoxShowsTheSettingAndReportsAClick() throws {
    let downloads = Downloads()
    var chosen: [Bool] = []
    downloads.autoUpgradeChosen = { on in
        chosen.append(on)
        downloads.autoUpgrade = on
    }
    downloads.show()
    let window = try #require(downloads.controller)
    let box = window.autoUpgradeBox
    #expect(box.state == .off)
    #expect(box.title == AppSettings().autoUpgrade.title)
    click(box)
    #expect(chosen == [true])
    #expect(box.state == .on)
    downloads.autoUpgrade = false
    #expect(box.state == .off)
    window.window?.close()
}

/// Beside it, while it's on, the albums the upgrades could still queue.
@MainActor
@Test func theUpgradeCountShowsOnlyWhileTheBoxIsOn() {
    let window = DownloadsWindow()
    window.showAutoUpgrade(true, left: 12)
    #expect(!window.upgradesLeft.isHidden)
    #expect(window.upgradesLeft.stringValue == "12 albums left to upgrade")
    window.showAutoUpgrade(true, left: 1)
    #expect(window.upgradesLeft.stringValue == "1 album left to upgrade")
    window.showAutoUpgrade(true, left: nil)
    #expect(window.upgradesLeft.isHidden, "not counted yet")
    window.showAutoUpgrade(false, left: 12)
    #expect(window.upgradesLeft.isHidden)
    window.window?.close()
}

/// The Upgrades sheet's Never Upgrade ends it with the ticked albums, and Not Found's one
/// policy is no choice to show.
@MainActor
@Test func aQueueSheetsSecondButtonGivesTheTickedAlbums() throws {
    let choices = [1, 2].map { (release: Int) in
        QueueChoice(
            title: "Album \(release)", detail: "", releaseID: release, upgrade: nil, refusal: nil)
    }
    let sheet = QueueSheet(
        heading: "Upgrades", note: "", choices: choices, policies: [.flac, .lossless],
        tickingAll: false, other: QueueChoice.neverUpgradeTitle)
    let never = try #require(sheet.otherButton)
    #expect(!never.isEnabled, "nothing ticked")
    sheet.toggle(1)
    #expect(never.isEnabled)
    click(never)
    #expect(sheet.marked == [choices[1]])
    #expect(sheet.result == nil)
    #expect(!sheet.policyPopUp.isHidden && sheet.policyPopUp.superview != nil)

    let again = QueueSheet(
        heading: "Not Found", note: "", choices: choices, policies: [.flac], tickingAll: true,
        button: Downloads.queueAgainTitle)
    #expect(again.otherButton == nil)
    #expect(again.queueButton.title == Downloads.queueAgainTitle)
    #expect(again.policyPopUp.superview == nil, "one policy is no choice")
}

@MainActor
@Test func notFoundSaysQueueAgainWaitsForTheBox() {
    let box = AppSettings().autoUpgrade.title
    #expect(Downloads.notFoundNote(autoUpgrade: true).hasSuffix("so it queues them in turn."))
    let off = Downloads.notFoundNote(autoUpgrade: false)
    #expect(off.contains("with \(box) off, nothing is queued until it's turned on"))
}

@MainActor
@Test func aJobsShowDiscographyItemComesFromItsRelease() {
    let downloads = Downloads()
    var asked: [Int] = []
    downloads.discographyItem = {
        asked.append($0)
        return NSMenuItem(title: "Show Discography", action: nil, keyEquivalent: "")
    }
    let window = downloads.makeWindow()
    #expect(window.discographyItem(4242)?.title == "Show Discography")
    #expect(asked == [4242])
    #expect(DownloadsWindow().discographyItem(1) == nil, "left out unless set")
    window.window?.close()
}
