import Testing

@testable import Library

@Test func aClickOnAStarSetsThatRatingAndOnTheRatingHeldClearsIt() {
    #expect(RatingClick.stars(at: -1, starWidth: 10, current: 3) == 0)
    #expect(RatingClick.stars(at: 0, starWidth: 10, current: 0) == 1)
    #expect(RatingClick.stars(at: 25, starWidth: 10, current: 0) == 3)
    #expect(RatingClick.stars(at: 25, starWidth: 10, current: 3) == 0)
    #expect(RatingClick.stars(at: 400, starWidth: 10, current: 1) == 5)
}
