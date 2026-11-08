import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

/// A browser over a copy of the shared browser library, showing every track, with the rows
/// `selected` selected.
@MainActor
private func browser(selecting selected: IndexSet) async throws -> (LibraryBrowser, LibraryIndex) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    await browser.load(BrowserState(source: nil))
    browser.table.table.selectRowIndexes(selected, byExtendingSelection: false)
    return (browser, index)
}

/// The track ID of the table's only selected row.
@MainActor
private func selectedTrack(_ browser: LibraryBrowser) -> Int64? {
    let rows = browser.table.table.selectedRowIndexes
    return rows.count == 1 ? browser.rowID(at: rows[rows.startIndex]) : nil
}

@MainActor @Test func theTrackMenuIsBothListsMenu() async throws {
    let (browser, _) = try await browser(selecting: [])
    let menu = NSMenu()
    browser.trackMenu = menu
    #expect(browser.table.table.menu === menu)
    #expect(browser.timeline.table.menu === menu)
}

@MainActor @Test func showAlbumAndShowArtistNarrowTheLibraryToTheTracksOwn() async throws {
    let (browser, index) = try await browser(selecting: [7])
    let track = try #require(selectedTrack(browser))
    let row = try #require(try index.rows(ids: [track]).first)
    browser.showSelection(in: .album)
    try await waitFor("the album") { browser.model.filter.album != nil }
    #expect(browser.model.filter.album == row.albumID)
    #expect(selectedTrack(browser) == track)
    let artist = try #require(try index.entryIDs(ofTrack: track, browser.model.filter).artist)
    browser.showSelection(in: .artist)
    try await waitFor("the artist") { browser.model.filter.artist != nil }
    #expect(browser.model.filter.artist == artist)
    #expect(browser.model.filter.album == nil)
    #expect(selectedTrack(browser) == track)
}

@MainActor @Test func showInAllMusicSelectsTheTracksInTheWholeLibrary() async throws {
    let (browser, index) = try await browser(selecting: [6])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    // All Music already shows them.
    #expect(!browser.canShowSelectionInAllMusic)
    let tracks = [browser.model.trackIDs[90], browser.model.trackIDs[60]]
    let mix = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(mix, trackIDs: [browser.model.trackIDs[0]] + tracks)
    await browser.model.setSource(.playlist(mix))
    browser.table.table.selectRowIndexes([], byExtendingSelection: false)
    #expect(!browser.canShowSelectionInAllMusic)
    browser.table.table.selectRowIndexes([1, 2], byExtendingSelection: false)
    #expect(browser.canShowSelectionInAllMusic)
    window.makeFirstResponder(nil)
    browser.showSelectionInAllMusic()
    let table = browser.table.table
    try await waitFor("the keys") { window.firstResponder === table }
    #expect(browser.showsAllMusic)
    #expect(table.selectedRowIndexes == [60, 90])
    #expect(Set(table.selectedRowIndexes.map { browser.model.trackIDs[$0] }) == Set(tracks))
    #expect(abs(table.rect(ofRow: 60).midY - table.visibleRect.midY) < 3 * table.rowHeight)
    #expect(window.firstResponder === table)
    #expect(!browser.canShowSelectionInAllMusic)
}

@MainActor @Test func openDiscogsReleaseReadsTheFirstSelectedTracksReleaseID() async throws {
    let (browser, index) = try await browser(selecting: [])
    #expect(try browser.selectedDiscogsReleaseID() == nil)
    let tagged = browser.model.trackIDs[3]
    try index.database.prepare("UPDATE tracks SET discogs_release_id = '42' WHERE file_id = ?")
        .run(tagged)
    browser.table.table.selectRowIndexes([2], byExtendingSelection: false)
    #expect(try browser.selectedDiscogsReleaseID() == nil)
    browser.table.table.selectRowIndexes([3, 2], byExtendingSelection: false)
    #expect(try browser.selectedDiscogsReleaseID() == nil)
    browser.table.table.selectRowIndexes([3], byExtendingSelection: false)
    #expect(try browser.selectedDiscogsReleaseID() == 42)
    browser.table.table.selectRowIndexes([3, 4], byExtendingSelection: false)
    #expect(try browser.selectedDiscogsReleaseID() == 42)
}

@MainActor @Test func addToPlaybackQueueSendsTheSelectedFiles() async throws {
    let (browser, _) = try await browser(selecting: [2, 5])
    let expected = try await browser.model.urls(ofRows: [2, 5])
    var queued: [[URL]] = []
    browser.addToQueue = { queued.append($0) }
    browser.addSelectionToQueue()
    try await waitFor("the queued files") { !queued.isEmpty }
    #expect(queued == [expected])
}

@MainActor @Test func showInPlaylistOffersThePlaylistsListingTheTrackAndShowsIt() async throws {
    let (browser, index) = try await browser(selecting: [4])
    let track = try #require(selectedTrack(browser))
    let other = browser.model.trackIDs[0]
    let mix = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(mix, trackIDs: [other, track])
    let elsewhere = try index.createPlaylist(named: "Elsewhere")
    _ = try index.addToPlaylist(elsewhere, trackIDs: [other])
    #expect(try browser.playlistsHoldingSelection().map(\.name) == ["Mix"])
    browser.showSelection(inPlaylist: mix)
    try await waitFor("the playlist") { browser.model.filter.source == .playlist(mix) }
    #expect(selectedTrack(browser) == track)
}

@MainActor @Test func showCurrentTrackWithNothingPlayingCentersTheSelection() async throws {
    let (browser, _) = try await browser(selecting: [])
    #expect(!browser.canShowCurrentTrack(playingPath: nil))
    #expect(browser.canShowCurrentTrack(playingPath: "/somewhere/playing.flac"))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    let table = browser.table.table
    let row = min(80, table.numberOfRows - 1)
    table.selectRowIndexes([row], byExtendingSelection: false)
    table.scrollRowToVisible(0)
    #expect(browser.canShowCurrentTrack(playingPath: nil))
    await browser.showCurrentTrack(playingPath: nil)
    #expect(table.selectedRowIndexes == [row])
    let visible = table.visibleRect
    #expect(abs(table.rect(ofRow: row).midY - visible.midY) < 3 * table.rowHeight)
    #expect(window.firstResponder === table)
}

@MainActor @Test func showSelectedTrackCentersTheSelectionWhateverPlays() async throws {
    let (browser, _) = try await browser(selecting: [])
    #expect(!browser.hasSelection)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    let table = browser.table.table
    let row = min(80, table.numberOfRows - 1)
    table.selectRowIndexes([row], byExtendingSelection: false)
    table.scrollRowToVisible(0)
    #expect(browser.hasSelection)
    browser.showSelectedTrack()
    #expect(table.selectedRowIndexes == [row])
    #expect(abs(table.rect(ofRow: row).midY - table.visibleRect.midY) < 3 * table.rowHeight)
    #expect(window.firstResponder === table)
}

@MainActor @Test func backAtAllMusicThePlayingTrackIsSelectedAndCentered() async throws {
    let (browser, index) = try await browser(selecting: [])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    let table = browser.table.table
    let row = min(80, table.numberOfRows - 1)
    let playing = try #require(try index.rows(ids: [browser.model.trackIDs[row]]).first)
    browser.showPlaying(path: playing.path)
    func centered(_ row: Int) -> Bool {
        abs(table.rect(ofRow: row).midY - table.visibleRect.midY) < 3 * table.rowHeight
    }
    for narrow in [
        { await browser.model.setSource(.history) }, { await browser.model.setSearch("a") },
    ] {
        table.selectRowIndexes([2], byExtendingSelection: false)
        await narrow()
        #expect(!browser.showsAllMusic)
        _ = await browser.model.showAll()
        #expect(table.selectedRowIndexes == [row])
        #expect(centered(row))
    }
    // A change within the whole library leaves the selection alone.
    table.selectRowIndexes([3], byExtendingSelection: false)
    await browser.model.setSearch("")
    #expect(table.selectedRowIndexes == [3])
}

@MainActor @Test func scrollingByRowsKeepsTheSelection() async throws {
    let (browser, _) = try await browser(selecting: [3])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    let table = browser.table.table
    let clip = try #require(table.enclosingScrollView?.contentView)
    let top = clip.bounds.minY
    browser.scrollTracks(byRows: 2)
    #expect(clip.bounds.minY == top + 2 * table.rowHeight)
    browser.scrollTracks(byRows: -1)
    #expect(clip.bounds.minY == top + table.rowHeight)
    browser.scrollTracks(byRows: -5)
    #expect(clip.bounds.minY == top)
    #expect(table.selectedRowIndexes == [3])
}
