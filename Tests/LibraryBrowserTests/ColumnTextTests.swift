import AppKit
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

@MainActor @Test func aDSDRateShowsAsItsMultiple() {
    var dsd = row
    dsd.codec = "dsd"
    dsd.sampleRateHz = 5_644_800
    dsd.bitsPerSample = 1
    #expect(TrackColumn.sampleRate.text(dsd, position: 0) == "DSD128")
    #expect(TrackColumn.sampleRate.text(row, position: 0) == "44.1 kHz")
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
    let art = EmbeddedArt(
        offset: offset, byteCount: 1, mimeType: "image/png", unsynchronised: false)
    return ArtRequest(
        key: ArtworkKey(path: "/a.flac", art: art), art: art,
        stamp: FileStamp(sizeBytes: 1, modifiedSeconds: 0))
}

@Test func artRequestsLoadTheNewestStillWantedAndStayBounded() {
    var requests = ArtRequests()
    for offset in 0..<3 { requests.add(request(offset)) }
    requests.add(request(0))
    #expect(requests.waiting.map(\.key.offset) == [1, 2, 0])
    let all = Set((0..<3).map { request($0).key })
    #expect(requests.next(wanted: all)?.key.offset == 0)
    #expect(requests.next(wanted: all.filter { $0.offset != 2 })?.key.offset == 1)
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

@Test func albumArtSpansItsAlbumsFirstRowsOnly() {
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

@Test func anAlbumsRunCountsItsRowsUpToTheLimit() {
    let albums: [Int64?] = [1, 1, 1, 1, 1, 1, nil, 2, 2]
    let length = { (start: Int, limit: Int) in
        ArtRun.length(from: start, limit: limit, rowCount: albums.count) { albums[$0] }
    }
    #expect(length(0, 3) == 3)
    #expect(length(0, 10) == 6)
    #expect(length(6, 3) == 1)
    #expect(length(7, 3) == 2)
}

@Test func fitScalesArtIntoItsAlbumsRowsAndFullWidthFillsTheColumn() {
    let square = CGSize(width: 500, height: 500)
    // Two 18-point rows under a 100-point column: fit is 36 points, centered across.
    #expect(
        ArtFrame.rect(.fit, image: square, width: 100, runHeight: 36)
            == CGRect(x: 32, y: 0, width: 36, height: 36))
    #expect(
        ArtFrame.rect(.fullWidth, image: square, width: 100, runHeight: 36)
            == CGRect(x: 0, y: 0, width: 100, height: 100))
    // A long album: fit fills the column too.
    #expect(
        ArtFrame.rect(.fit, image: square, width: 100, runHeight: 200)
            == CGRect(x: 0, y: 0, width: 100, height: 100))
    // Wide art fits the square, at its top.
    #expect(
        ArtFrame.whole(image: CGSize(width: 400, height: 200), width: 100)
            == CGRect(x: 0, y: 0, width: 100, height: 50))
    #expect(ArtFrame.whole(image: .zero, width: 100) == .zero)
}

@MainActor @Test func rowArtLoadsAtAPowerOfTwoForTheColumn() {
    #expect(RowArt.pixels(columnWidth: 20) == 64)
    #expect(RowArt.pixels(columnWidth: 34) == 128)
    #expect(RowArt.pixels(columnWidth: 120) == 256)
    #expect(RowArt.pixels(columnWidth: 2000) == RowArt.largestPixels)
}

@MainActor @Test func theViewerFitsArtAsLargeAsTheScreenAllowsCentered() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    #expect(
        ArtViewer.frame(of: CGSize(width: 300, height: 300), in: screen)
            == CGRect(x: 282.5, y: 0, width: 875, height: 875))
    #expect(
        ArtViewer.frame(of: CGSize(width: 4000, height: 1000), in: screen)
            == CGRect(x: 0, y: 257.5, width: 1440, height: 360))
}

@MainActor @Test func theViewerClosesOnEscOrAClick() throws {
    let screen = try #require(NSScreen.main)
    for close in ["esc", "click"] {
        let viewer = ArtViewer(
            image: NSImage(size: NSSize(width: 10, height: 10)), screen: screen, owner: nil)
        var closed = 0
        viewer.closed = { closed += 1 }
        viewer.show()
        #expect(viewer.window.isVisible)
        let view = try #require(viewer.window.contentView)
        if close == "esc" {
            let esc = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: viewer.window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            view.keyDown(with: esc)
        } else {
            let click = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: viewer.window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            view.mouseDown(with: click)
        }
        #expect(!viewer.window.isVisible, "\(close)")
        #expect(closed == 1, "\(close)")
    }
}

@MainActor @Test func aDecodeFinishingAfterTheViewerClosedIsDropped() async throws {
    let screen = try #require(NSScreen.main)
    let viewer = ArtViewer(
        image: NSImage(size: NSSize(width: 10, height: 10)), screen: screen, owner: nil)
    var failures: [String] = []
    viewer.show()
    let art = EmbeddedArt(offset: 0, byteCount: 10, mimeType: "image/png", unsynchronised: false)
    let late = viewer.load(art, path: "/nonexistent/art.flac") { failures.append($0) }
    viewer.close()
    await late.value
    #expect(failures.isEmpty)
    // While open, the same failure is reported.
    viewer.show()
    await viewer.load(art, path: "/nonexistent/art.flac") { failures.append($0) }.value
    #expect(failures.count == 1)
    viewer.close()
}

@MainActor @Test func theViewerClosesWithItsWindowOrWhenTheAppResignsActive() throws {
    let screen = try #require(NSScreen.main)
    let owner = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
        backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    for event in [NSWindow.willCloseNotification, NSApplication.didResignActiveNotification] {
        let viewer = ArtViewer(
            image: NSImage(size: NSSize(width: 10, height: 10)), screen: screen, owner: owner)
        viewer.show()
        NotificationCenter.default.post(
            name: event, object: event == NSWindow.willCloseNotification ? owner : NSApp)
        #expect(!viewer.window.isVisible, "\(event.rawValue)")
    }
}
