import Testing

@testable import Library

@Test func aClickOnAStarSetsThatRatingAndOnTheRatingHeldClearsIt() {
    #expect(RatingClick.stars(at: -1, starWidth: 10, current: 3) == 0)
    #expect(RatingClick.stars(at: 0, starWidth: 10, current: 0) == 1)
    #expect(RatingClick.stars(at: 25, starWidth: 10, current: 0) == 3)
    #expect(RatingClick.stars(at: 25, starWidth: 10, current: 3) == 0)
    #expect(RatingClick.stars(at: 400, starWidth: 10, current: 1) == 5)
}

@Test func hoveringFillsUpToTheStarUnderThePointer() {
    #expect(RatingClick.hovered(at: -1, starWidth: 10) == 0)
    #expect(RatingClick.hovered(at: 0, starWidth: 10) == 1)
    #expect(RatingClick.hovered(at: 39.9, starWidth: 10) == 4)
    #expect(RatingClick.hovered(at: 400, starWidth: 10) == 5)
    #expect(RatingClick.hovered(at: 5, starWidth: 0) == 0)
}

/// Tracks rated differently have no rating of their own to clear: a click sets the star's.
@Test func aClickOverMixedRatingsSetsTheStarsRating() {
    #expect(RatingClick.stars(at: 25, starWidth: 10, current: nil) == 3)
    #expect(RatingClick.stars(at: -1, starWidth: 10, current: nil) == 0)
}
