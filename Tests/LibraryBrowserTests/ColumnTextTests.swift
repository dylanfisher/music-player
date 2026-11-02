import Artwork
import Foundation
import Metadata
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor private let row: TrackRow = {
    var row = TrackRow(
        id: 1, path: "/m/a.flac", title: "A", artist: nil, album: nil, albumID: nil,
        albumArtist: nil, genre: nil, date: nil, trackNumber: 3, discNumber: nil, codec: "flac",
        sampleRateHz: 44_100, bitsPerSample: 16, durationSeconds: 1, addedSeconds: 0, art: nil)
    row.trackTotal = 12
    row.bitRateKbps = 1411.2
    row.sizeBytes = 4_200_000
    row.loved = true
    return row
}()

@MainActor @Test func theRowNumberIsThePositionShownAndTotalsReadAsOf() {
    #expect(TrackColumn.rowNumber.text(row, position: 0) == "1")
    #expect(TrackColumn.rowNumber.text(row, position: 41) == "42")
    #expect(TrackColumn.trackOfTotal.text(row, position: 0) == "3 of 12")
    #expect(TrackColumn.discOfTotal.text(row, position: 0) == "")
    var noTotal = row
    noTotal.trackTotal = nil
    #expect(TrackColumn.trackOfTotal.text(noTotal, position: 0) == "3")
    #expect(TrackColumn.bitRate.text(row, position: 0) == "1411 kbps")
    #expect(TrackColumn.size.text(row, position: 0) == "4.2 MB")
    #expect(TrackColumn.loved.text(row, position: 0) == "\u{2665}")
    #expect(!TrackColumn.rowNumber.isSortable)
    #expect(TrackColumn.allCases.filter { !$0.isSortable } == [.rowNumber])
}

/// Album Art, Title, Artist, Album, Track of Total, Time, Year, Genre, Grouping, Catalog Number,
/// Bit Rate, Sample Rate, Size, Play Count and Date Added, after the row number.
@Test func theOwnersSixteenColumnsFitBesideTheSidebarAndQueueAt1440Points() {
    let columns: [TrackColumn] = [
        .rowNumber, .art, .title, .artist, .album, .trackOfTotal, .duration, .year, .genre,
        .grouping, .catalogNumber, .bitRate, .sampleRate, .size, .playCount, .dateAdded,
    ]
    let state = AppState()
    // Each column's width and the table's 6-point spacing between them, and beside the table
    // the sidebar, the queue, their dividers and the scroller.
    let table = columns.reduce(0) { $0 + $1.defaultWidth + 6 }
    let besides = Double(state.sidebarWidth.defaultValue + state.queueWidth.defaultValue) + 10
    #expect(table + besides <= 1440, "\(table) points of columns")
}

private func request(_ offset: Int) -> ArtRequest {
    ArtRequest(
        key: ArtworkKey(path: "/a.flac", offset: offset),
        art: EmbeddedArt(offset: offset, byteCount: 1, mimeType: "image/png", unsynchronised: false)
    )
}

@Test func artRequestsLoadTheNewestStillWantedAndStayBounded() {
    var requests = ArtRequests()
    for offset in 0..<3 { requests.add(request(offset)) }
    requests.add(request(0))
    #expect(requests.waiting.map(\.key.offset) == [1, 2, 0])
    #expect(requests.next { _ in true }?.key.offset == 0)
    #expect(requests.next { $0.offset != 2 }?.key.offset == 1)
    #expect(requests.waiting.isEmpty)
    for offset in 0..<(ArtRequests.capacity + 10) { requests.add(request(offset)) }
    #expect(requests.waiting.count == ArtRequests.capacity)
    #expect(requests.waiting.first?.key.offset == 10)
}

@Test func everyDefaultWidthIsOneASavedLayoutAccepts() {
    for column in TrackColumn.allCases {
        #expect(TrackTableLayout.widthRange.contains(column.defaultWidth), "\(column)")
    }
}

@Test func fullWidthArtSpansItsAlbumsFirstRowsOnly() {
    // Rows 0 to 5 are album 1, 6 has no album, 7 and 8 are album 2.
    let albums: [Int64?] = [1, 1, 1, 1, 1, 1, nil, 2, 2]
    let starts = albums.indices.map { row in
        ArtRun.start(of: row, rowsTall: 3) { albums[$0] }
    }
    #expect(starts == [0, 0, 0, nil, nil, nil, 6, 7, 7])
    var looked: Set<Int> = []
    _ = ArtRun.start(of: 5, rowsTall: 3) { row in
        looked.insert(row)
        return albums[row]
    }
    #expect(looked == [2, 3, 4, 5])
}
