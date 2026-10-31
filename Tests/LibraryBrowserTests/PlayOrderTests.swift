import Testing

@testable import LibraryBrowser

@Test func oneRowPlaysEverythingFromIt() {
    let (rows, first) = playOrder(rowCount: 5, selected: [2], clicked: 2)
    #expect(rows == [0, 1, 2, 3, 4])
    #expect(first == 2)
    // A click outside a selection counts as that row alone.
    #expect(playOrder(rowCount: 5, selected: [0, 1], clicked: 3) == ([0, 1, 2, 3, 4], 3))
}

@Test func severalRowsPlayInTableOrderThenTheRestAfterThem() {
    let (rows, first) = playOrder(rowCount: 8, selected: [5, 1, 3], clicked: 3)
    #expect(rows == [1, 3, 5, 6, 7])
    #expect(first == 0)
}
