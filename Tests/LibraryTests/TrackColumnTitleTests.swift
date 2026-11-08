import Settings
import Testing

@testable import Library

@Test func theOfTotalColumnsHaveShortHeaders() {
    #expect(TrackColumn.trackOfTotal.headerTitle == "Track No.")
    #expect(TrackColumn.discOfTotal.headerTitle == "Disc No.")
    #expect(TrackColumn.trackOfTotal.title == "Track of Total")
    #expect(TrackColumn.discOfTotal.title == "Disc of Total")
}

@Test func everyOtherHeaderIsTheTitle() {
    for column in TrackColumn.allCases where ![.trackOfTotal, .discOfTotal].contains(column) {
        #expect(column.headerTitle == column.title)
    }
}
