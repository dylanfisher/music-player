import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor
private func removalBrowser() throws -> (LibraryBrowser, LibraryIndex, [Int64]) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false)
    // Never the real Trash: a test that reaches it fails.
    browser.trash = { urls in
        Issue.record("moved \(urls) to the Trash")
        return TrashOutcome(moved: [], failure: nil)
    }
    let ids = try index.database.prepare("SELECT file_id FROM tracks ORDER BY file_id LIMIT 2")
        .map { try $0.int64(0) }
    return (browser, index, ids)
}

@Test func theQuestionCountsTheTracks() {
    #expect(removalQuestion(count: 1) == "Remove Track?")
    #expect(removalQuestion(count: 3) == "Remove 3 Tracks?")
}

@MainActor @Test func removingFromTheLibraryKeepsThePathsAndRestoringScansTheirFolders()
    async throws
{
    let (browser, index, ids) = try removalBrowser()
    let paths = try index.paths(ids: ids)
    let count = try index.trackCount()

    await browser.remove(ids, .library)
    #expect(try index.trackCount() == count - 2)
    #expect(try index.removedPaths().map(\.id).sorted() == ids)

    var restored: [String] = []
    browser.restored = { restored += $0 }
    await browser.restore([ids[0]])
    #expect(restored == [paths[ids[0]]!.precomposedStringWithCanonicalMapping])
    #expect(try index.removedPaths().map(\.id) == [ids[1]])
}

@MainActor @Test func onlyTheFilesTheTrashTookLeaveTheLibrary() async throws {
    let (browser, index, ids) = try removalBrowser()
    let paths = try index.paths(ids: ids)
    var given: [URL] = []
    browser.trash = { urls in
        given = urls
        return TrashOutcome(
            moved: [URL(fileURLWithPath: paths[ids[0]]!, isDirectory: false)],
            failure: "not permitted")
    }

    await browser.remove(ids, .trash)
    #expect(Set(given.map(\.path)) == Set(paths.values))
    #expect(try index.track(path: paths[ids[0]]!) == nil)
    #expect(try index.track(path: paths[ids[1]]!) != nil)
    // A trashed file isn't kept out of later scans.
    #expect(try index.removedPaths().isEmpty)
    #expect(browser.statusText == "couldn't move 1 of the files to the Trash: not permitted")
}

@MainActor @Test func removingTakesTheSelectionOnlyWhileATrackListHasTheKeys() async throws {
    let (browser, _, _) = try removalBrowser()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = NSStackView(views: [browser.sidebar.view, browser.content.view])
    await browser.load(BrowserState(source: nil))
    try await waitFor("the tracks") { browser.rowID(at: 0) != nil }
    browser.focusTracks()
    browser.selectAllTracks()
    #expect(browser.canRemoveSelection)
    // ⌫ in the sidebar or a pane leaves the track table's selection alone.
    let areas = browser.focusAreas
    for area in [areas[0], areas[1]] {
        #expect(window.makeFirstResponder(area))
        #expect(browser.hasSelectedTracks && !browser.canRemoveSelection)
    }
}
