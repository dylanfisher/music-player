import Testing

@testable import Library
@testable import LibraryBrowser
@testable import MusicPlayer
@testable import Palette
@testable import Settings

@Test func sameTitledAlbumsAreEachListedWithTheirArtist() {
    let (items, shown) = libraryItems([
        (.artist, BrowserEntry(id: 1, name: "Abba")),
        (.album, BrowserEntry(id: 7, name: "Greatest Hits", artist: "Abba")),
        (.album, BrowserEntry(id: 8, name: "Greatest Hits", artist: "Queen")),
    ])
    let queen = LibraryKey.album("Greatest Hits", by: "Queen")
    #expect(
        items.map(\.key) == ["artist:Abba", LibraryKey.album("Greatest Hits", by: "Abba"), queen])
    #expect(Set(items.map(\.key)).count == 3)
    #expect(items.map(\.detail) == ["Artist", "Album — Abba", "Album — Queen"])
    #expect(shown[queen]?.1 == 8)
}

@Test func playlistsAreListedByIDWithTheirKind() {
    let items = playlistItems([
        Playlist(id: 4, name: "Mix", kind: .manual),
        Playlist(id: 9, name: "Mix", kind: .smart(SmartRules(match: .all, rules: []))),
    ])
    #expect(items.map(\.key) == [LibraryKey.playlist(4), LibraryKey.playlist(9)])
    #expect(items.map(\.kind) == [.playlist, .playlist])
    #expect(items.map(\.detail) == ["Playlist", "Smart Playlist"])
    // The palette's key reads back as the source the sidebar shows.
    #expect(items.map { BrowserSource(text: $0.key) } == [.playlist(4), .playlist(9)])
}

@Test func goToItemOverTheTimelineListsEachPlayAndFindsItsRow() {
    // One track played twice: two rows, each named by its play's history ID.
    let names = [
        TrackName(id: 31, title: "Song", artist: "A", album: nil, genre: nil),
        TrackName(id: 30, title: "Song", artist: "A", album: nil, genre: nil),
    ]
    let items = goToItems(names)
    #expect(items.map(\.key) == ["track:0:31", "track:1:30"])
    var shown: [Int64] = [31, 30]
    let rowID = { (row: Int) in shown.indices.contains(row) ? shown[row] : nil }
    #expect(goToRow(items[1].key, rowID: rowID) == 1)
    // A new play above shifts the rows, so the old key no longer names that row.
    shown.insert(32, at: 0)
    #expect(goToRow(items[1].key, rowID: rowID) == nil)
    #expect(goToRow("track:x:1", rowID: rowID) == nil)
}

@Test func commandsListGenresAndGoToItemListsArtistsAndAlbums() {
    #expect(listedPanes(.commands) == [.genre])
    #expect(listedPanes(.goToItem) == [.artist, .album])
}

@Test func eachOutputIsAPaletteRowThatReadsBackAsItsChoice() {
    let options = outputOptions(
        devices: [FoundOutput(id: "DAC", name: "ADI-2 DAC")],
        renderers: [FoundOutput(id: "uuid:denon", name: "Denon")], current: .device(uid: "DAC"))
    let items = outputItems(options, current: .device(uid: "DAC"))
    #expect(items.map(\.title) == ["Output: System Default", "Output: ADI-2 DAC", "Output: Denon"])
    #expect(items.map(\.detail) == ["Output", "In use", "Output"])
    #expect(items.map(\.kind) == [.output, .output, .output])
    #expect(items.map { OutputChoice(text: $0.key) } == options.map(\.choice))
}
