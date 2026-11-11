import AppKit
import Artwork
import Foundation
import Testing

@testable import BarView
@testable import Library
@testable import NowPlaying
@testable import Playback
@testable import Settings

private let path = "/m/a.flac"

/// The index's rating of the playing file, which a test changes; nil when the index doesn't
/// have the file. `reads` counts the bar's lookups.
@MainActor
private final class Index {
    var rating: Int? = 0
    var reads = 0
}

@MainActor
private func bar(_ index: Index) -> NowPlayingBar {
    let model = NowPlayingModel { path in
        index.reads += 1
        return index.rating.map { rating in
            var row = TrackRow(
                id: 1, path: path, title: "Song", artist: nil, album: nil, albumID: 1,
                albumArtist: nil, genre: nil, date: nil, trackNumber: nil, discNumber: nil,
                codec: "flac", sampleRateHz: 44100, bitsPerSample: 16, durationSeconds: 100,
                addedSeconds: 0, art: nil)
            row.rating = rating
            return row
        }
    }
    return NowPlayingBar(model: model, artwork: ArtworkLoader(maxPixelSize: 8, capacity: 1))
}

private func playing(_ current: Int?) -> PlaybackUpdate {
    var state = PlaybackState()
    state.queue = [URL(fileURLWithPath: path, isDirectory: false)]
    state.order = [0]
    state.currentIndex = current
    state.status = current == nil ? .stopped : .playing
    state.durationSeconds = current.map { _ in 100 }
    return PlaybackUpdate(state: state, event: current == nil ? .stopped : .trackStarted(index: 0))
}

/// The status bar's stars and the toolbar's, its status and each Custom Status item.
@MainActor
private func stars(of bar: NowPlayingBar) -> [RatingStars] {
    [bar.statusBar.rating, bar.header.rating] + bar.customStatuses.map(\.rating)
}

/// Each bar's Rating part is its stars.
@MainActor @Test func theRatingPartIsTheStars() {
    let bar = bar(Index())
    #expect(bar.statusBar.view(for: .rating) === bar.statusBar.rating)
    #expect(bar.header.view(for: .rating) === bar.header.rating)
    #expect(bar.customStatuses.allSatisfy { $0.view(for: .rating) === $0.rating })
}

/// The stars fill up to the playing track's rating, and an unrated track's are all empty.
@MainActor @Test func theStarsSayZeroToFiveStars() {
    let index = Index()
    let bar = bar(index)
    bar.apply(playing(0))
    let texts = ["☆☆☆☆☆", "★☆☆☆☆", "★★☆☆☆", "★★★☆☆", "★★★★☆", "★★★★★"]
    for (rating, text) in texts.enumerated() {
        bar.ratingsChanged(rating) { _ in true }
        for view in stars(of: bar) {
            #expect(view.text == text, "\(rating) stars")
            #expect(view.isEnabled && view.alphaValue == 1)
        }
    }
}

/// With nothing playing the stars keep their place unseen, out of VoiceOver's reach, and take
/// no click, as the art does; a file the index doesn't have shows them empty and off, since it
/// can't be rated.
@MainActor @Test func theStarsShowOnlyWhileATrackPlays() {
    let index = Index()
    index.rating = 3
    let bar = bar(index)
    let unseen = { (view: RatingStars) in
        view.alphaValue == 0 && !view.isEnabled && !view.isAccessibilityElement()
    }
    #expect(stars(of: bar).allSatisfy(unseen))
    bar.apply(playing(0))
    #expect(
        stars(of: bar).allSatisfy {
            $0.alphaValue == 1 && $0.isEnabled && $0.rating == 3 && $0.isAccessibilityElement()
        })
    bar.apply(playing(nil))
    #expect(stars(of: bar).allSatisfy(unseen))
    index.rating = nil
    bar.apply(playing(0))
    for view in stars(of: bar) {
        #expect(view.alphaValue == 1 && !view.isEnabled && view.text == "☆☆☆☆☆")
    }
}

/// A rating set on the playing track shows in every bar, without reading the index: from the
/// app, a shortcut, the menu, a table click or Get Info. Another track's changes nothing, and a
/// sync shows through the library's refresh, which reads the index.
@MainActor @Test func theStarsFollowARatingSetWhilePlaying() {
    let index = Index()
    index.rating = 2
    let bar = bar(index)
    bar.apply(playing(0))
    #expect(stars(of: bar).allSatisfy { $0.rating == 2 })
    let reads = index.reads
    bar.ratingsChanged(4) { $0.path == "/m/b.flac" }
    #expect(stars(of: bar).allSatisfy { $0.rating == 2 }, "another track's rating")
    bar.ratingsChanged(4) { $0.path == path }
    #expect(stars(of: bar).allSatisfy { $0.rating == 4 })
    bar.ratingsChanged(0) { $0.path == path }
    #expect(stars(of: bar).allSatisfy { $0.text == "☆☆☆☆☆" })
    #expect(index.reads == reads)
    index.rating = 1
    bar.libraryChanged()
    #expect(stars(of: bar).allSatisfy { $0.rating == 1 })
}

/// The stars clicked show the click's rating at once; after a write that failed they show the
/// track's rating again.
@MainActor @Test func theStarsClickedGoBackAfterAFailedWrite() {
    let index = Index()
    index.rating = 2
    let bar = bar(index)
    bar.apply(playing(0))
    let width = bar.header.rating.intrinsicContentSize.width / 5
    bar.header.rating.click(atX: width * 3.5)
    #expect(bar.header.rating.rating == 4)
    bar.ratingsChanged(nil) { _ in true }
    #expect(stars(of: bar).allSatisfy { $0.rating == 2 })
}

/// The click's rating stays while its write isn't done, through a playback update that shows
/// the bars again, until the bars hear how the write went.
@MainActor @Test func theClicksRatingStaysWhileItsWriteIsPending() {
    let index = Index()
    index.rating = 2
    let bar = bar(index)
    bar.apply(playing(0))
    let width = bar.header.rating.intrinsicContentSize.width / 5
    bar.header.rating.click(atX: width * 3.5)
    bar.apply(PlaybackUpdate(state: playing(0).state, event: nil))
    #expect(stars(of: bar).allSatisfy { $0.rating == 4 })
    bar.ratingsChanged(nil) { _ in true }
    #expect(stars(of: bar).allSatisfy { $0.rating == 2 })
}

/// A click on any bar's stars rates the playing track by its path, and a click on its rating
/// clears it; with nothing playing a click does nothing.
@MainActor @Test func aClickOnTheStarsRatesThePlayingTrack() {
    let index = Index()
    index.rating = 2
    let bar = bar(index)
    var rated: [String] = []
    bar.ratingClicked = { rated.append("\($0) \($1)") }
    bar.statusBar.rating.click(atX: 0)
    #expect(rated.isEmpty)
    bar.apply(playing(0))
    let width = bar.header.rating.intrinsicContentSize.width / 5
    bar.header.rating.click(atX: width * 3.5)
    let statusWidth = bar.statusBar.rating.intrinsicContentSize.width / 5
    bar.statusBar.rating.click(atX: statusWidth * 1.5)
    #expect(rated == ["4 \(path)", "0 \(path)"])
}

/// The stars sit where a mouse down on a view that allows it drags the window, the title bar
/// and with glass a full-size content view; a mouse down on them rates instead, even the first
/// one in a window that isn't active, unless they take no click.
@MainActor @Test func aMouseDownOnTheStarsMovesTheWindowOnlyWhileTheyreOff() throws {
    let bar = bar(Index())
    bar.apply(playing(0))
    bar.header.apply(
        BarLayout(
            center: BarColumn(parts: [.title, .rating], width: .flexible, alignment: .leading)))
    let status = bar.header.view
    status.frame = NSRect(x: 0, y: 0, width: 400, height: status.fittingSize.height)
    status.layoutSubtreeIfNeeded()
    let stars = bar.header.rating
    let frame = stars.convert(stars.bounds, to: status)
    #expect(frame.width > 0)
    let hit = try #require(status.hitTest(NSPoint(x: frame.midX, y: frame.midY)))
    #expect(hit === stars)
    #expect(!hit.mouseDownCanMoveWindow)
    #expect(hit.acceptsFirstMouse(for: nil))
    bar.apply(playing(nil))
    #expect(stars.mouseDownCanMoveWindow && bar.statusBar.rating.mouseDownCanMoveWindow)
}
