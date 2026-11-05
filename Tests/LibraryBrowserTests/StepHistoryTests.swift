import AppKit
import Foundation
import Playback
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

private func window(_ source: BrowserSource?, search: String = "") -> WindowPlace {
    WindowPlace(filter: TrackFilter(source: source, search: search))
}

private func spot(_ name: String, at seconds: Double = 0) -> PlaybackSpot {
    PlaybackSpot(
        queue: [URL(fileURLWithPath: "/music/\(name).flac", isDirectory: false)], index: 0,
        seconds: seconds, status: .playing)
}

private let stopped = PlaybackSpot(queue: [], index: nil, seconds: 0, status: .stopped)

@Test func backAndForwardStepThroughTheSources() {
    var history = StepHistory(start: window(nil))
    history.visit(window(.timeline), leaving: window(nil))
    history.visit(window(.timeline), leaving: window(.timeline))
    history.visit(window(.playlist(1)), leaving: window(.timeline))
    #expect(history.back(leaving: window(.playlist(1)), playing: nil)?.window == window(.timeline))
    #expect(history.back(leaving: window(.timeline), playing: nil)?.window == window(nil))
    #expect(history.back(leaving: window(nil), playing: nil) == nil)
    #expect(history.forward(leaving: window(nil), playing: nil)?.window == window(.timeline))
    history.visit(window(.history), leaving: window(.timeline))
    #expect(!history.canGoForward)
    #expect(history.back(leaving: window(.history), playing: nil)?.window == window(.timeline))
}

@Test func forgettingASourceKeepsThePlaceAndDropsRepeats() {
    var history = StepHistory(start: window(nil))
    history.visit(window(.playlist(1)), leaving: window(nil))
    history.visit(window(nil), leaving: window(.playlist(1)))
    history.visit(window(.playlist(2)), leaving: window(nil))
    history.remove { $0 == .playlist(1) }
    #expect(history.back(leaving: window(.playlist(2)), playing: nil)?.window == window(nil))
    #expect(history.back(leaving: window(nil), playing: nil) == nil)
    #expect(history.forward(leaving: window(nil), playing: nil)?.window == window(.playlist(2)))
}

@Test func aPlayInADeletedPlaylistStaysAStepShowingTheLibrary() {
    var history = StepHistory(start: window(nil))
    history.visit(window(.playlist(1)), leaving: window(nil))
    history.play(spot("a"), replacing: stopped, from: window(.playlist(1), search: "a"))
    history.remove { $0 == .playlist(1) }
    let back = history.back(leaving: window(nil), playing: spot("a", at: 5))
    #expect(back == StepHistory.Move(window: window(nil), playback: stopped))
    #expect(!history.canGoBack)
}

@Test func backOverAPlayPutsBackWhatItReplacedAndForwardWhereItGotTo() {
    var history = StepHistory(start: window(nil))
    history.play(spot("a"), replacing: stopped, from: window(nil, search: "a"))
    // Where A had got to when B replaced it, and the window B was started from.
    history.play(spot("b"), replacing: spot("a", at: 30), from: window(nil, search: "b"))
    let back = history.back(leaving: window(nil, search: "later"), playing: spot("b", at: 4))
    #expect(back == StepHistory.Move(window: window(nil, search: "b"), playback: spot("a", at: 30)))
    let forward = history.forward(leaving: window(nil, search: "b"), playing: spot("a", at: 31))
    #expect(
        forward
            == StepHistory.Move(window: window(nil, search: "later"), playback: spot("b", at: 4)))
    // Back again puts back A where Forward found it.
    #expect(history.back(leaving: window(nil), playing: nil)?.playback == spot("a", at: 31))
    let first = history.back(leaving: window(nil), playing: nil)
    #expect(first == StepHistory.Move(window: window(nil, search: "a"), playback: stopped))
}

@Test func aSourceBetweenPlaysIsAStepThatLeavesPlaybackAlone() {
    var history = StepHistory(start: window(nil))
    history.play(spot("a"), replacing: stopped, from: window(nil))
    history.visit(window(.history), leaving: window(nil, search: "where a was"))
    history.play(spot("b"), replacing: spot("a", at: 30), from: window(.history))
    #expect(history.back(leaving: window(.history), playing: nil)?.playback == spot("a", at: 30))
    let place = history.back(leaving: window(.history), playing: nil)
    #expect(place == StepHistory.Move(window: window(nil, search: "where a was"), playback: nil))
    #expect(history.canGoBack)
}

@Test func aStepAfterBackDropsTheStepsAhead() {
    var history = StepHistory(start: window(nil))
    history.play(spot("a"), replacing: stopped, from: window(nil))
    history.play(spot("b"), replacing: spot("a", at: 30), from: window(nil))
    _ = history.back(leaving: window(nil), playing: spot("b", at: 2))
    #expect(history.canGoForward)
    history.play(spot("c"), replacing: spot("a", at: 30), from: window(nil))
    #expect(!history.canGoForward)
    #expect(history.steps.count == 3)
}

@Test func thePlaySourceIsWhereThePlaybackInPlaceStarted() {
    var history = StepHistory(start: window(nil))
    #expect(history.playSource == nil)
    history.play(spot("a"), replacing: stopped, from: window(.playlist(1), search: "a"))
    history.visit(window(nil), leaving: window(.playlist(1), search: "later"))
    // Leaving the play's step changes its window, not where it started.
    #expect(history.playSource == TrackFilter(source: .playlist(1), search: "a"))
    history.play(spot("b"), replacing: spot("a"), from: window(.timeline))
    #expect(history.playSource == TrackFilter(source: .timeline))
    _ = history.back(leaving: window(nil), playing: spot("b"))
    #expect(history.playSource == TrackFilter(source: .playlist(1), search: "a"))
    _ = history.back(leaving: window(nil), playing: nil)
    _ = history.back(leaving: window(nil), playing: nil)
    #expect(history.playSource == nil)
}

// MARK: In the browser

/// A browser in a window, showing the library, with an engine stand-in behind its plays.
@MainActor
private final class Stand {
    let browser: LibraryBrowser
    let window: NSWindow
    /// What the stand-in engine plays.
    var playback = PlaybackSpot(queue: [], index: nil, seconds: 0, status: .stopped)
    var plays = 0
    var restores = 0

    /// Over the shared library, or over `databaseURL`, a copy a test writes playlists to.
    init(databaseURL: URL? = nil) async throws {
        let databaseURL = try databaseURL ?? browserLibrary.get().databaseURL
        browser = LibraryBrowser(
            reader: try LibraryReader(databaseURL: databaseURL),
            index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
            browserHeight: 100, groupByAlbumArtist: false, thumbnails: nil)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = browser.content.view
        await browser.load(BrowserState(source: nil))
        window.layoutIfNeeded()
        browser.currentPlayback = { [unowned self] in playback }
        browser.restorePlayback = { [unowned self] spot in
            playback = spot
            restores += 1
        }
        browser.playStart = { [unowned self] start in
            playback = PlaybackSpot(queue: [start.url], index: 0, seconds: 0, status: .playing)
            plays += 1
        }
        browser.play = { [unowned self] request in
            playback = PlaybackSpot(
                queue: request.urls, index: request.first, seconds: 0, status: .playing)
            plays += 1
        }
    }

    var model: BrowserModel { browser.model }

    /// Selects the track at `row`, scrolled to `top`, and plays the selection.
    func play(row: Int, top: Int) async throws {
        browser.table.scroll(toRow: top)
        browser.table.select([row])
        let before = plays
        browser.playSelection()
        try await waitFor("the play") { plays == before + 1 }
        await browser.stepping?.value
    }

    func back() async {
        browser.back()
        await browser.stepping?.value
    }

    func forward() async {
        browser.forward()
        await browser.stepping?.value
    }

    func search(_ text: String) async {
        browser.searchField.stringValue = text
        await model.setSearch(text)
    }

    var selectedIDs: Set<Int64> { Set(model.ids(ofRows: browser.table.table.selectedRowIndexes)) }
    var topID: Int64? { browser.table.scrollAnchor(in: model.trackIDs)?.id }
}

@MainActor @Test func backUndoesAPlayWithTheWindowAsItWasAndForwardRedoesIt() async throws {
    let stand = try await Stand()
    let model = stand.model
    #expect(!stand.browser.canGoBack)
    try await stand.play(row: 70, top: 60)
    let a = stand.playback
    let windowA = (selection: stand.selectedIDs, top: stand.topID, ids: model.trackIDs)
    #expect(stand.browser.canGoBack)
    stand.playback.seconds = 30

    await stand.search("a")
    try await stand.play(row: 3, top: 2)
    let b = stand.playback
    #expect(b != a)
    let windowB = (selection: stand.selectedIDs, top: stand.topID, ids: model.trackIDs)
    stand.playback.seconds = 4
    // Browsing after the play isn't a step.
    await stand.search("ab")
    stand.browser.table.select([0])
    let browsed = stand.selectedIDs

    await stand.back()
    // A again, from where B replaced it, still playing, in the window B was played from.
    #expect(stand.playback == PlaybackSpot(queue: a.queue, index: 0, seconds: 30, status: .playing))
    #expect(stand.browser.searchField.stringValue == "a")
    #expect(model.filter.search == "a")
    #expect(model.trackIDs == windowB.ids)
    #expect(stand.selectedIDs == windowB.selection)
    #expect(stand.topID == windowB.top)
    #expect(stand.browser.canGoForward)

    await stand.forward()
    #expect(stand.playback == PlaybackSpot(queue: b.queue, index: 0, seconds: 4, status: .playing))
    #expect(model.filter.search == "ab")
    #expect(stand.selectedIDs == browsed)
    #expect(!stand.browser.canGoForward)

    await stand.back()
    await stand.back()
    // Before the first play nothing played, and the window was as A was played from.
    #expect(stand.playback.status == .stopped)
    #expect(stand.browser.searchField.stringValue == "")
    #expect(model.trackIDs == windowA.ids)
    #expect(stand.selectedIDs == windowA.selection)
    #expect(stand.topID == windowA.top)
    #expect(!stand.browser.canGoBack)
    #expect(stand.restores == 4)
    #expect(stand.plays == 2)
}

@MainActor @Test func aSourceBetweenPlaysIsItsOwnStep() async throws {
    let stand = try await Stand()
    try await stand.play(row: 3, top: 0)
    await stand.model.setSource(.history)
    #expect(stand.browser.canGoBack)
    await stand.back()
    // Back over the source shows the library and leaves playback alone.
    #expect(stand.model.filter.source == nil)
    #expect(stand.restores == 0)
    #expect(stand.browser.canGoBack)
    await stand.back()
    #expect(stand.restores == 1)
    #expect(stand.playback.status == .stopped)
    #expect(!stand.browser.canGoBack)
}

@MainActor @Test func aPlayAfterBackDropsForward() async throws {
    let stand = try await Stand()
    try await stand.play(row: 3, top: 0)
    try await stand.play(row: 5, top: 0)
    await stand.back()
    #expect(stand.browser.canGoForward)
    try await stand.play(row: 7, top: 0)
    #expect(!stand.browser.canGoForward)
    #expect(stand.browser.canGoBack)
}

// MARK: Show Current Track

/// A stand over a writable library with a playlist listing two of its tracks, its ID, the
/// index, and the path of each track by ID.
@MainActor
private func standWithPlaylist() async throws -> (
    Stand, playlist: Int64, index: LibraryIndex, paths: [Int64: String]
) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let stand = try await Stand(databaseURL: databaseURL)
    let ids = stand.model.trackIDs
    let playlist = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(playlist, trackIDs: [ids[5], ids[40]])
    try await stand.model.reloadPlaylists()
    let paths = Dictionary(
        uniqueKeysWithValues: try index.rows(ids: Array(ids)).map { ($0.id, $0.path) })
    return (stand, playlist, index, paths)
}

@MainActor @Test func showCurrentTrackGoesToTheSourceThePlayStartedIn() async throws {
    let (stand, playlist, _, paths) = try await standWithPlaylist()
    let model = stand.model
    let track = model.trackIDs[40]
    let path = try #require(paths[track])

    // Played from the library, shown from the playlist that lists it too.
    try await stand.play(row: 40, top: 30)
    await model.setSource(.playlist(playlist))
    stand.browser.table.select([0])
    await stand.browser.showCurrentTrack(playingPath: path)
    #expect(model.filter.source == nil)
    #expect(stand.selectedIDs == [track])

    // Played from the playlist, with a search, shown from the library.
    await model.setSource(.playlist(playlist))
    let word = try #require(
        try await model.allTrackNames().first { $0.id == track }?.title.split(separator: " ")
            .first)
    await stand.search(String(word))
    let row = try #require(model.rows(holding: [track]).first)
    try await stand.play(row: row, top: 0)
    await stand.search("")
    await model.setSource(nil)
    await stand.browser.showCurrentTrack(playingPath: path)
    #expect(model.filter.source == .playlist(playlist))
    #expect(model.filter.search == String(word))
    #expect(stand.browser.searchField.stringValue == String(word))
    #expect(stand.selectedIDs == [track])
    // It's a step Back can undo.
    await stand.back()
    #expect(model.filter.source == nil)
}

@MainActor @Test func showCurrentTrackFallsBackToTheLibrary() async throws {
    let (stand, playlist, index, paths) = try await standWithPlaylist()
    let model = stand.model
    let track = model.trackIDs[40]
    let path = try #require(paths[track])
    await model.setSource(.playlist(playlist))
    let row = try #require(model.rows(holding: [track]).first)
    try await stand.play(row: row, top: 0)
    await model.setSource(.history)

    // Taken out of the playlist it started in.
    try index.removeFromPlaylist(playlist, trackIDs: [track])
    await stand.browser.showCurrentTrack(playingPath: path)
    #expect(model.filter.source == nil)
    #expect(stand.selectedIDs == [track])

    // The playlist deleted.
    await model.setSource(.history)
    try index.deletePlaylist(playlist)
    try await model.reloadPlaylists()
    await stand.browser.showCurrentTrack(playingPath: path)
    #expect(model.filter.source == nil)
    #expect(stand.selectedIDs == [track])
}

@MainActor @Test func showCurrentTrackGoesBackToTheTimelinesPlay() async throws {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    for (seconds, row) in rows.prefix(5).enumerated() {
        try index.recordPlay(row.path, at: Double(seconds))
    }
    let stand = try await Stand(databaseURL: databaseURL)
    let browser = stand.browser
    await stand.model.setSource(.timeline)
    try await waitFor("the timeline") { browser.timelineModel.entries.count == 5 }
    browser.timeline.table.selectRowIndexes([2], byExtendingSelection: false)
    let track = browser.timelineModel.entries[2].trackID
    let before = stand.plays
    browser.playSelection()
    try await waitFor("the play") { stand.plays == before + 1 }
    await browser.stepping?.value

    await stand.model.setSource(nil)
    let path = try #require(rows.first { $0.id == track }?.path)
    await browser.showCurrentTrack(playingPath: path)
    #expect(stand.model.filter.source == .timeline)
    #expect(browser.timeline.table.selectedRowIndexes == [2])
}

// MARK: Undo Selection

@MainActor @Test func undoSelectionAfterShowCurrentTrackSelectsTheClickedTrack() async throws {
    let stand = try await Stand()
    let browser = stand.browser
    let model = stand.model
    #expect(!browser.canUndoSelection)
    try await stand.play(row: 10, top: 0)
    let playing = model.trackIDs[10]
    let path = try #require(try await browser.selectedPaths().first)
    browser.table.table.selectRowIndexes([20], byExtendingSelection: false)
    let clicked = model.trackIDs[20]
    await browser.showCurrentTrack(playingPath: path)
    #expect(stand.selectedIDs == [playing])

    #expect(browser.canUndoSelection)
    browser.undoSelection()
    await browser.stepping?.value
    #expect(stand.selectedIDs == [clicked])
    #expect(browser.canRedoSelection)
    browser.redoSelection()
    await browser.stepping?.value
    #expect(stand.selectedIDs == [playing])
    #expect(!browser.canRedoSelection)
    // Playback is left alone.
    #expect(stand.plays == 1)
    #expect(stand.restores == 0)
}

@MainActor @Test func aRunOfArrowKeysIsUndoneInOneStep() async throws {
    let stand = try await Stand()
    let browser = stand.browser
    browser.focusTracks()
    browser.table.table.selectRowIndexes([5], byExtendingSelection: false)
    for _ in 0..<3 { #expect(browser.moveSelection(.down, extending: false)) }
    #expect(browser.moveSelection(.down, extending: true))
    #expect(browser.table.table.selectedRowIndexes == [8, 9])
    browser.undoSelection()
    await browser.stepping?.value
    #expect(browser.table.table.selectedRowIndexes == [5])
}

@MainActor @Test func undoSelectionShowsTheSourceItsStepWasIn() async throws {
    let (stand, playlist, _, _) = try await standWithPlaylist()
    let browser = stand.browser
    let model = stand.model
    let inLibrary = model.trackIDs[40]
    browser.table.table.selectRowIndexes([40], byExtendingSelection: false)
    await model.setSource(.playlist(playlist))
    browser.table.table.selectRowIndexes([0], byExtendingSelection: false)
    let inPlaylist = model.trackIDs[0]
    browser.undoSelection()
    await browser.stepping?.value
    #expect(model.filter.source == nil)
    #expect(stand.selectedIDs == [inLibrary])
    browser.redoSelection()
    await browser.stepping?.value
    #expect(model.filter.source == .playlist(playlist))
    #expect(stand.selectedIDs == [inPlaylist])
}
