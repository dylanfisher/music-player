import AppKit
import Testing

@testable import BarView
@testable import Library
@testable import Metadata
@testable import TagEditor

private func track(_ path: String, rating: Int?) -> EditableTrack {
    EditableTrack(path: path, tags: TrackTags(), pictures: [], rating: rating)
}

/// The stars show the rating the tracks share, nil where they differ; a rating set goes to
/// every track the index has and is no edit for Save.
@Test func theRatingIsSharedOrMixedAndIsntAnEdit() throws {
    var model = TagEditorModel(tracks: [track("/a.flac", rating: 3), track("/b.flac", rating: 3)])
    #expect(model.shownRating == 3)
    #expect(TagEditorModel(tracks: [track("/a.flac", rating: 0)]).shownRating == 0)
    #expect(TagEditorModel(tracks: [track("/a.flac", rating: nil)]).shownRating == 0)
    let mixed = TagEditorModel(tracks: [track("/a.flac", rating: 1), track("/b.flac", rating: 0)])
    #expect(mixed.shownRating == nil)

    var some = TagEditorModel(tracks: [track("/a.flac", rating: 2), track("/b.flac", rating: nil)])
    #expect(some.ratedPaths == ["/a.flac"])
    some.setRating(5)
    #expect(some.tracks.map(\.rating) == [5, nil])
    #expect(try some.edit().isEmpty)
    model.showRatings([4, 1])
    #expect(model.shownRating == nil)
}

/// Info's stars at the title's right: hovering fills up to the star under the pointer, a
/// click sets that rating at once, and a click on the rating the tracks have clears it.
@MainActor @Test func theInfoTabsStarsHoverAndRate() throws {
    let editor = TagEditorWindow(paths: ["/a.flac", "/b.flac"])
    defer { editor.close() }
    var rated: [Int] = []
    editor.rated = { rated.append($0) }
    editor.load(
        TagEditorModel(tracks: [track("/a.flac", rating: 2), track("/b.flac", rating: 4)]))
    let stars = editor.ratingStars
    #expect(stars.isEnabled)
    #expect(stars.rating == nil, "rated differently")
    #expect(stars.toolTip == "Mixed")
    let width = stars.intrinsicContentSize.width / 5
    stars.hover(atX: width * 2.5)
    #expect(stars.filled == 3)
    stars.hover(atX: nil)
    #expect(stars.filled == 0)
    stars.click(atX: width * 3.5)
    #expect(rated == [4], "a click over mixed ratings sets the star's")
    #expect(editor.model?.tracks.map(\.rating) == [4, 4])
    #expect(stars.rating == 4)
    stars.hover(atX: width * 3.5)
    stars.click(atX: width * 3.5)
    #expect(rated == [4, 0])
    #expect(stars.rating == 0)
    #expect(stars.filled == 0, "a click that clears shows no star under the pointer")
    stars.hover(atX: width * 1.5)
    stars.isEnabled = false
    #expect(stars.filled == 0, "the stars turned off drop the hover")
    stars.isEnabled = true
    #expect(try editor.model?.edit().isEmpty == true, "no tag is written")
    // A rating set elsewhere shows.
    editor.showRatings([1, 1])
    #expect(stars.rating == 1)
}

/// A rating out of range draws no more than five stars and no fewer than none.
@MainActor @Test func theStarsKeepARatingOutOfRangeToFive() {
    let stars = RatingStars(fontPoints: 11)
    stars.rating = 7
    #expect(stars.filled == 5 && stars.text == "★★★★★")
    stars.rating = -1
    #expect(stars.filled == 0 && stars.text == "☆☆☆☆☆")
}

/// Tracks the index doesn't have can't be rated.
@MainActor @Test func theStarsAreOffWithNoTrackInTheIndex() {
    let editor = TagEditorWindow(paths: ["/a.flac"])
    defer { editor.close() }
    var rated: [Int] = []
    editor.rated = { rated.append($0) }
    editor.load(TagEditorModel(tracks: [track("/a.flac", rating: nil)]))
    #expect(!editor.ratingStars.isEnabled)
    editor.ratingStars.click(atX: 10)
    #expect(rated.isEmpty)
}
