import AppKit
import Foundation
import Testing

@testable import Library
@testable import LibraryBrowser
@testable import Playback
@testable import Settings

/// A browser in a window over `databaseURL`, loaded with `resume`, playing nothing.
@MainActor
private func browser(_ databaseURL: URL, resume: ResumePoint? = nil) async throws -> (
    LibraryBrowser, NSWindow
) {
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false, thumbnails: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = browser.content.view
    browser.currentPlayback = { PlaybackSpot(queue: [], index: nil, seconds: 0, status: .stopped) }
    await browser.load(BrowserState(source: nil), resume: resume)
    window.layoutIfNeeded()
    return (browser, window)
}

@MainActor
private func config(_ url: URL) throws -> ConfigStore<AppSettings> {
    ConfigStore(AppSettings(), fileURL: url, check: { _, _, _ in nil }, creating: true)
}

@MainActor @Test func aPlayStateWrittenAtQuitPutsBackTheTrackPausedAndTheWindow() async throws {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let (first, firstWindow) = try await browser(databaseURL)
    let library = first.model.trackIDs
    let listed = Array(library[10..<90])
    let playlist = try index.createPlaylist(named: "Evening")
    _ = try index.addToPlaylist(playlist, trackIDs: listed)
    try await first.model.reloadPlaylists()
    var started: PlayStart?
    first.playStart = { started = $0 }

    // Played from the playlist, then a row further down selected and the list scrolled.
    await first.model.setSource(.playlist(playlist))
    first.table.select([10])
    first.playSelection()
    try await waitFor("the play") { started != nil }
    await first.stepping?.value
    let played = try #require(started).url.path
    first.table.scroll(toRow: 30)
    first.table.select([40])
    let selected = first.model.trackIDs[40]
    let top = try #require(first.listPlace().scroll?.id)
    let point = try #require(first.resumePoint(playing: (played, 42.5)))
    #expect(point.seconds == 42.5)
    #expect(point.from == point.source)
    firstWindow.close()

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("play-state-\(UUID().uuidString)/config.json")
    try config(url).set(\.resume, to: point)
    let read = try config(url)[\.resume]
    #expect(read == point)

    let (second, secondWindow) = try await browser(databaseURL, resume: read)
    defer { secondWindow.close() }
    #expect(second.model.filter.source == .playlist(playlist))
    #expect(Array(second.model.ids(ofRows: second.table.table.selectedRowIndexes)) == [selected])
    #expect(second.listPlace().scroll?.id == top)

    let resumed = try #require(await second.resumedPlayback(read))
    #expect(resumed.spot.status == .paused)
    #expect(resumed.spot.seconds == 42.5)
    let paths = try index.paths(ids: listed)
    #expect(resumed.spot.queue.map(\.path) == listed.compactMap { paths[$0] })
    #expect(resumed.spot.index.map { resumed.spot.queue[$0].path } == played)
    #expect(resumed.durationSeconds > 0)

    // A play from the list the queue was restored from plays in that queue.
    let next = try #require(resumed.spot.index) + 1
    let start = try #require(try await second.model.playStart(selected: [], clicked: next))
    #expect(start.queue == PlayRequest(urls: resumed.spot.queue, first: next))

    // Show Current Track goes to where the resumed track was played from.
    await second.model.setSource(nil)
    await second.showCurrentTrack(playingPath: played)
    #expect(second.model.filter.source == .playlist(playlist))
}

@MainActor @Test func aSavedTrackThisLibraryLacksStartsWithNothingLoaded() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let point = ResumePoint(
        track: "music/library/Gone/01 Gone.flac", seconds: 12, from: nil, source: "history",
        selected: "/nowhere/02.flac", top: nil)
    let (browser, window) = try await browser(databaseURL, resume: point)
    defer { window.close() }
    #expect(await browser.resumedPlayback(point) == nil)
    #expect(browser.model.filter.source == .history)
    #expect(browser.table.table.selectedRowIndexes.isEmpty)
}
