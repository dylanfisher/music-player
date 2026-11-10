import AppKit
import Foundation
import Settings
import Testing

@testable import Fixtures
@testable import Library
@testable import LibraryBrowser

/// A browser in a window, and a temporary library folder holding a copy of a fixture file
/// whose tags read, at a path that isn't its layout's, and one more file outside it.
@MainActor
private func organizingBrowser() throws -> (
    LibraryBrowser, NSWindow, library: String, inside: String, outside: String
) {
    let databaseURL = try writableBrowserDatabase()
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false, thumbnails: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = browser.content.view
    let source = try browserLibrary.get().root
    let fixture = try #require(
        try loadManifest(in: URL(fileURLWithPath: source, isDirectory: true)).files.first {
            $0.malformation == nil && $0.tags?.title != nil && $0.container == .flac
        })
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("organizing-\(UUID().uuidString)").resolvingSymlinksInPath().path
    let library = root + "/Library"
    try FileManager.default.createDirectory(
        atPath: library + "/Loose", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: root + "/Elsewhere", withIntermediateDirectories: true)
    let inside = library + "/Loose/misnamed.flac"
    let outside = root + "/Elsewhere/outside.flac"
    try FileManager.default.copyItem(atPath: source + "/" + fixture.path, toPath: inside)
    try FileManager.default.copyItem(atPath: source + "/" + fixture.path, toPath: outside)
    return (browser, window, library, inside, outside)
}

/// Holds the count until the test opens it, and says whether it saw the stop.
private final class CountGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    // `seen` is guarded by `lock`.
    private let lock = NSLock()
    private var seen = false

    func open() { semaphore.signal() }

    /// A count that tells one path checked, waits for `open`, then checks for the stop before
    /// the rest, as `layoutMoves` does.
    var count: OrganizeCount {
        { paths, folder, counted, stopped in
            counted(1, 0)
            self.semaphore.wait()
            guard !stopped() else {
                self.lock.withLock { self.seen = true }
                return FilesOrganized()
            }
            return layoutMoves(paths, libraryFolder: folder)
        }
    }

    var stopSeen: Bool { lock.withLock { seen } }
}

@MainActor @Test func organizeSelectedFilesOpensAtOnceAndCancelStopsTheCount() async throws {
    let (browser, window, library, inside, outside) = try organizingBrowser()
    let gate = CountGate()
    browser.countOrganizing = gate.count
    var organized: [FilesOrganized] = []
    let run = Task {
        await browser.organizeFiles({ [inside, outside] }, in: library, over: window) { plan, _ in
            organized.append(plan)
        }
    }
    try await waitFor("the count's first file") {
        browser.organizeSheet?.detail.stringValue.hasPrefix("Checked 1 of 2 tracks") == true
    }
    let sheet = try #require(browser.organizeSheet)
    #expect(sheet.heading.stringValue == OrganizeSheet.countingTitle)
    #expect(sheet.organizeButton.isHidden)
    #expect(sheet.bar.doubleValue == 0.5)
    click(sheet.cancelButton)
    gate.open()
    await run.value
    #expect(gate.stopSeen)
    #expect(organized.isEmpty)
    #expect(browser.organizeSheet == nil)
}

@MainActor @Test func organizeSelectedFilesAsksWithTheCountThatWillMoveAndSkipsTheRest()
    async throws
{
    let (browser, window, library, inside, outside) = try organizingBrowser()
    var organized: [FilesOrganized] = []
    for answer in [false, true] {
        let run = Task {
            await browser.organizeFiles({ [inside, outside] }, in: library, over: window) {
                plan, _ in organized.append(plan)
            }
        }
        try await waitFor("the question") { browser.organizeSheet?.asking == true }
        let sheet = try #require(browser.organizeSheet)
        #expect(sheet.heading.stringValue == "Organize 1 File?")
        #expect(sheet.detail.stringValue.contains("1 not in the library folder"))
        #expect(!sheet.organizeButton.isHidden && sheet.bar.isHidden)
        click(answer ? sheet.organizeButton : sheet.cancelButton)
        await run.value
    }
    // Cancel organizes nothing; Organize hands on the plan it asked about.
    let plan = try #require(organized.first)
    #expect(organized.count == 1)
    #expect(plan.moved.map(\.from) == [inside])
    #expect(plan.outside == [outside])
    // Asking renames nothing.
    #expect(FileManager.default.fileExists(atPath: inside))
}

@MainActor @Test func organizeSelectedFilesWithNothingToMoveClosesWithoutAsking() async throws {
    let (browser, window, library, _, outside) = try organizingBrowser()
    await browser.organizeFiles(
        { [outside] }, in: library, over: window,
        organize: { _, _ in Issue.record("organized with nothing to move") })
    #expect(browser.organizeSheet == nil)
    #expect(browser.status.organizedReport.map(\.line).first?.contains(outside) == true)
    await browser.organizeFiles(
        { [outside] }, in: nil, over: window,
        organize: { _, _ in Issue.record("organized with no library folder") })
}

@MainActor @Test func theRenamesShowInTheStatusBarUntilTheyFinish() throws {
    let (browser, _, _, _, _) = try organizingBrowser()
    browser.showOrganizing(OrganizeProgress(done: 1, total: 4, current: "/l/Artist/Album/a.flac"))
    #expect(browser.status.activityText == "Organizing files: 3 left · Album/a.flac")
    #expect(browser.status.activityFraction == 0.25)
    browser.showOrganizing(OrganizeProgress(done: 4, total: 4, current: nil))
    #expect(browser.status.activityText == "Organizing files: finishing")
    var organized = FilesOrganized()
    organized.moved = [TrackMove(from: "/l/a.flac", to: "/l/A/a.flac")]
    browser.finishOrganizing(organized, carry: LayoutCarry())
    #expect(browser.status.activityText == nil)
    #expect(browser.statusText == "Organized 1 file")
}

@Test func theResultLineCountsTheFilesAndTheProblems() {
    #expect(organizedSummary(moved: 2340, problems: 3) == "Organized 2,340 files; 3 problems")
    #expect(organizedSummary(moved: 1, problems: 1) == "Organized 1 file; 1 problem")
    #expect(organizedSummary(moved: 0, problems: 0) == "No files to organize")
}

@MainActor @Test func whatWasntMovedIsListedInTheProblemsWindow() throws {
    let (browser, _, _, _, _) = try organizingBrowser()
    var organized = FilesOrganized()
    organized.moved = [TrackMove(from: "/l/a.flac", to: "/l/A/a.flac")]
    organized.problems = ["/l/b.flac: not moved, /l/A/b.flac is already there"]
    let carry = LayoutCarry(
        carried: [], problems: ["the stats of /l/a.flac didn't follow it to /l/A/a.flac: locked"])
    browser.finishOrganizing(organized, carry: carry)
    #expect(
        browser.status.organizedReport.map(\.line) == [
            "/l/b.flac: not moved, /l/A/b.flac is already there",
            "the stats of /l/a.flac didn't follow it to /l/A/a.flac: locked",
        ])
    #expect(browser.status.problemLines.contains(browser.status.organizedReport[0].line))
}
