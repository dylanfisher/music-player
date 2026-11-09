import AppKit
import Foundation
import Library
import Settings
import Testing

@testable import LibraryBrowser
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
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.contentView = browser.content.view
    await browser.load(BrowserState(source: .timeline))
    let deadline = Date().addingTimeInterval(10)
    while browser.rowID(at: 0) == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    browser.focusTracks()
    browser.selectAllTracks()
    #expect(browser.hasSelectedTracks)
    // Remove… takes the timeline's selection, as it takes the track table's.
    #expect(browser.canRemoveSelection)
    // ⌘⌫ still removes nothing: the timeline is no playlist.
    #expect(
        removalTarget(
            queueFocused: false, queueHasSelection: false,
            tracksFocused: browser.tracksHaveFocus,
            canRemoveFromPlaylist: browser.canRemoveFromPlaylist) == nil)
}

@Test func pastingAddsOnlyToTheQueueOrAPlaylist() {
    #expect(pasteTarget(queueFocused: true, canPasteInPlaylist: false) == .queue)
    #expect(pasteTarget(queueFocused: false, canPasteInPlaylist: true) == .playlist)
    // The library, a smart playlist, the sidebar or a pane.
    #expect(pasteTarget(queueFocused: false, canPasteInPlaylist: false) == nil)
}

@Test func aPasteFindsTheCopiedFilesOnlyWhileThePasteboardHoldsTheCopy() {
    let clipboard = TrackClipboard(paths: ["/m/a.flac"], changeCount: 7)
    #expect(clipboard.paths(atChangeCount: 7) == ["/m/a.flac"])
    #expect(clipboard.paths(atChangeCount: 8) == nil)
}
