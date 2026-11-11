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

/// Tracks the library no longer lists, as after a rescan removed them, are said to be gone
/// rather than leaving All Music with nothing selected.
@MainActor @Test func showInAllMusicSaysSoWhenNoneOfTheTracksIsListed() async throws {
    let (browser, index) = try await browser(selecting: [])
    var beeps = 0
    browser.beep = { beeps += 1 }
    let gone = browser.model.trackIDs[10]
    let mix = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(mix, trackIDs: [gone])
    await browser.model.setSource(.playlist(mix))
    browser.table.table.selectRowIndexes([0], byExtendingSelection: false)
    try index.database.prepare("DELETE FROM tracks WHERE file_id = ?").run(gone)
    browser.showSelectionInAllMusic()
    try await waitFor("the message") { browser.statusText == LibraryBrowser.notInAllMusicText }
    #expect(browser.showsAllMusic)
    #expect(beeps == 1)
    #expect(browser.table.table.selectedRowIndexes.isEmpty)
}

/// Open Discogs Release reads the first selected row's release id when it runs, and says so
/// when that track has none.
@MainActor @Test func openDiscogsReleaseOpensTheFirstSelectedTracksRelease() async throws {
    let (browser, index) = try await browser(selecting: [])
    var opened: [Int] = []
    var beeps = 0
    browser.beep = { beeps += 1 }
    browser.openSelectedRelease { opened.append($0) }
    #expect(opened.isEmpty && beeps == 0, "nothing selected, nothing to say")
    let tagged = browser.model.trackIDs[3]
    try index.database.prepare("UPDATE tracks SET discogs_release_id = '42' WHERE file_id = ?")
        .run(tagged)
    browser.table.table.selectRowIndexes([2, 3], byExtendingSelection: false)
    browser.openSelectedRelease { opened.append($0) }
    #expect(opened.isEmpty)
    #expect(beeps == 1)
    #expect(browser.statusText == LibraryBrowser.noReleaseIDText)
    browser.table.table.selectRowIndexes([3, 4], byExtendingSelection: false)
    browser.openSelectedRelease { opened.append($0) }
    #expect(opened == [42])
    #expect(beeps == 1)
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

/// Copy reads the selected rows' names and files; Paste adds to a manual playlist only, after
/// the selection, and never to the library (ADR 0161).
@MainActor @Test func pasteAddsCopiedTracksToTheManualPlaylistAfterTheSelection() async throws {
    let (browser, index) = try await browser(selecting: [4, 7])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.makeFirstResponder(browser.table.table)
    #expect(browser.canCopySelection)
    let copies = try await browser.selectedCopies()
    let rows = try index.rows(ids: [browser.model.trackIDs[4], browser.model.trackIDs[7]])
    #expect(copies == rows.map(CopiedTrack.init))
    // Not in the library.
    #expect(!browser.canPaste)

    let mix = try index.createPlaylist(named: "Mix")
    let kept = Array(browser.model.trackIDs[20..<23])
    _ = try index.addToPlaylist(mix, trackIDs: kept)
    try await browser.model.reloadPlaylists()
    await browser.model.setSource(.playlist(mix))
    window.makeFirstResponder(browser.table.table)
    #expect(browser.canPaste)
    browser.table.table.selectRowIndexes([0], byExtendingSelection: false)
    browser.paste(copies.map(\.path) + ["/not/in/the/library.flac"])
    let pasted = [kept[0]] + rows.map(\.id) + kept[1...]
    try await waitFor("the pasted tracks") { browser.model.trackIDs == pasted }
    try await waitFor("the message") {
        browser.statusText.contains("aren't in the library") == true
    }
}

/// A paste keeps the order the tracks were copied in, one the playlist had included.
@MainActor @Test func pastedTracksKeepTheirCopiedOrder() async throws {
    let (browser, index) = try await browser(selecting: [])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = browser.content.view
    let new = browser.model.trackIDs[30]
    let kept = Array(browser.model.trackIDs[20..<23])
    let paths = try index.paths(ids: [new, kept[2]])
    let mix = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(mix, trackIDs: kept)
    try await browser.model.reloadPlaylists()
    await browser.model.setSource(.playlist(mix))
    window.makeFirstResponder(browser.table.table)
    browser.table.table.selectRowIndexes([0], byExtendingSelection: false)
    browser.paste([try #require(paths[new]), try #require(paths[kept[2]])])
    let pasted = [kept[0], new, kept[2], kept[1]]
    try await waitFor("the pasted tracks") { browser.model.trackIDs == pasted }
}

/// Control-Down in the track table selects the next album's first track, and with Shift
/// extends to it.
@MainActor @Test func theTrackTableMovesByAlbum() async throws {
    let (browser, index) = try await browser(selecting: [0])
    let albums = try index.rows(ids: browser.model.trackIDs).map(\.albumID)
    let next = try #require(albums.indices.first { albums[$0] != albums[0] })
    browser.table.move(.nextAlbum, extending: false)
    await browser.table.albumMovesDone()
    #expect(browser.table.table.selectedRowIndexes == [next])
    browser.table.move(.previousAlbum, extending: true)
    await browser.table.albumMovesDone()
    #expect(browser.table.table.selectedRowIndexes == IndexSet(0...next))
}

/// The Rating submenu's marks, from Clear Rating to five stars.
@MainActor
private func ratingMarks(_ browser: LibraryBrowser) -> [RatingMark] {
    (0...5).map(browser.selectionRatingMark)
}

@MainActor @Test func theRatingSubmenuMarksTheSelectedTracksRatings() async throws {
    let (browser, index) = try await browser(selecting: [2])
    let ids = try browser.selectedTrackIDs()
    #expect(ratingMarks(browser) == [.on, .off, .off, .off, .off, .off])
    try index.setRating(4, trackIDs: ids)
    #expect(ratingMarks(browser) == [.off, .off, .off, .off, .on, .off])
    // Several alike.
    browser.table.table.selectRowIndexes([2, 3], byExtendingSelection: false)
    let both = try browser.selectedTrackIDs()
    try index.setRating(4, trackIDs: both)
    #expect(ratingMarks(browser) == [.off, .off, .off, .off, .on, .off])
    // Several rated differently, one unrated among them.
    browser.table.table.selectRowIndexes([2, 3, 4], byExtendingSelection: false)
    try index.setRating(2, trackIDs: [both[1]])
    #expect(ratingMarks(browser) == [.mixed, .off, .mixed, .off, .mixed, .off])
    // A rating set from the menu shows at its next check.
    browser.rateSelection(5)
    try await waitFor("the rating") { browser.selectionRatingMark(5) == .on }
    #expect(ratingMarks(browser) == [.off, .off, .off, .off, .off, .on])
    browser.table.table.selectRowIndexes([], byExtendingSelection: false)
    #expect(ratingMarks(browser) == [.off, .off, .off, .off, .off, .off])
}

@Test func theRatingMessageNamesOneTrackOrCountsSeveral() {
    #expect(ratingMessage(stars: 4, count: 1, title: "Song") == "Rated “Song” ★★★★")
    #expect(ratingMessage(stars: 4, count: 3, title: nil) == "Rated 3 tracks ★★★★")
    #expect(ratingMessage(stars: 0, count: 1, title: "Song") == "Cleared the rating of “Song”")
    #expect(ratingMessage(stars: 0, count: 2, title: nil) == "Cleared the rating of 2 tracks")
}

@MainActor @Test func ratingFromTheMenuSaysSoAndANewerMessageOutlivesTheOldersFade() async throws {
    let (browser, index) = try await browser(selecting: [2])
    let title = try #require(try index.rows(ids: try browser.selectedTrackIDs()).first?.title)
    #expect(browser.ratingMessageText == nil)
    browser.rateSelection(4)
    try await waitFor("the message") { browser.ratingMessageText != nil }
    #expect(browser.ratingMessageText == "Rated “\(title)” ★★★★")
    browser.table.table.selectRowIndexes([2, 3, 4], byExtendingSelection: false)
    browser.rateSelection(0)
    try await waitFor("the second message") {
        browser.ratingMessageText == "Cleared the rating of 3 tracks"
    }
    // The first message's fade, due now, leaves the second showing.
    browser.fadeRatingMessage(1)
    #expect(browser.ratingMessageText == "Cleared the rating of 3 tracks")
    browser.fadeRatingMessage(2)
    try await waitFor("the fade") { browser.ratingMessageText == nil }
}

/// Get Info rates by path; every rating the browser sets tells the info windows.
@MainActor @Test func ratingByPathRatesTheTracksAndSaysTheRatingsChanged() async throws {
    let (browser, index) = try await browser(selecting: [2])
    var changes = 0
    browser.ratingsChanged = { changes += 1 }
    let id = try #require(try browser.selectedTrackIDs().first)
    let path = try #require(try index.paths(ids: [id])[id])
    browser.setRating(3, paths: [path, "/not/in/the/index.flac"])
    try await waitFor("the rating") { changes == 1 }
    #expect(try index.rows(ids: [id]).first?.rating == 3)
    browser.rateSelection(1)
    try await waitFor("the second rating") { changes == 2 }
    #expect(try index.rows(ids: [id]).first?.rating == 1)
}
