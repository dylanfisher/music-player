import AppKit
import Foundation
import Testing

@testable import BarView
@testable import Library
@testable import LibraryBrowser
@testable import MusicPlayer
@testable import NowPlaying
@testable import Playback

/// Waits a turn of the main queue at a time, up to about five seconds, for `condition`.
@MainActor
private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(condition(), "timed out waiting for \(what)")
}

/// A click on the status bar's stars rates the playing track in the index, and a rating the
/// browser sets, here Get Info's, shows in the status bar and the toolbar.
@MainActor @Test func theBarsStarsRateThroughTheBrowserAndFollowIt() async throws {
    let databaseURL = try writableWindowLibrary()
    let fixture = try await MainWindowFixture(databaseURL: databaseURL)
    defer { fixture.close() }
    let index = try LibraryIndex(at: databaseURL)
    let id = try #require(fixture.browser.model.trackIDs.first)
    let path = try #require(try index.paths(ids: [id])[id])
    var state = PlaybackState()
    state.queue = [URL(fileURLWithPath: path, isDirectory: false)]
    state.order = [0]
    state.currentIndex = 0
    state.status = .playing
    fixture.nowPlaying.apply(PlaybackUpdate(state: state, event: .trackStarted(index: 0)))
    let stars = fixture.nowPlaying.statusBar.rating
    #expect(stars.isEnabled && stars.rating == 0)

    let width = stars.intrinsicContentSize.width / 5
    stars.click(atX: width * 2.5)
    try await waitFor("the click's rating in the index") {
        (try? index.track(path: path))??.rating == 3
    }
    fixture.browser.setRating(5, paths: [path])
    try await waitFor("the browser's rating in the bars") {
        [stars, fixture.nowPlaying.header.rating].allSatisfy { $0.rating == 5 }
    }
}
