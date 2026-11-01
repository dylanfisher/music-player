import AppKit
import Foundation
import Library
import LibraryBrowser
import Settings
import Testing

@testable import MusicPlayer

@Test func removingTakesOnlyFromTheListWithTheKeys() {
    func target(_ queue: Bool, _ queueSelection: Bool, _ tracks: Bool, _ playlist: Bool) -> Removal?
    {
        removalTarget(
            queueFocused: queue, queueHasSelection: queueSelection, tracksFocused: tracks,
            canRemoveFromPlaylist: playlist)
    }
    #expect(target(true, true, false, true) == .queue)
    #expect(target(true, false, false, true) == nil)
    #expect(target(false, true, true, true) == .playlist)
    // The sidebar, a pane or anything else: nothing, even with selections in both lists.
    #expect(target(false, true, false, true) == nil)
    #expect(target(false, false, true, false) == nil)
}

@MainActor @Test func theDeleteChordRemovesNothingFromTheTimeline() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("timeline-removal-\(UUID().uuidString)")
    let databaseURL = libraryFileURL(in: directory)
    let index = try LibraryIndex(at: databaseURL)
    try index.recordPlay("/Music/a.flac", at: 1)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, folders: [],
        groupByAlbumArtist: false)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.contentView = browser.content.view
    await browser.load(BrowserState(source: .timeline, genre: nil, artist: nil, album: nil))
    let deadline = Date().addingTimeInterval(10)
    while browser.rowID(at: 0) == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    browser.focusTracks()
    browser.selectAllTracks()
    #expect(browser.hasSelectedTracks)
    // The timeline has the keys and a selection, and still nothing is removed.
    #expect(
        removalTarget(
            queueFocused: false, queueHasSelection: false,
            tracksFocused: browser.tracksHaveFocus,
            canRemoveFromPlaylist: browser.canRemoveFromPlaylist) == nil)
}
