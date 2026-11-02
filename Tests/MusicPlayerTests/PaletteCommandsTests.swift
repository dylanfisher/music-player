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

@Test func goToItemKeysEachTrackByItsID() {
    let names = [
        TrackName(id: 31, title: "Song", artist: "A", album: "B", genre: nil),
        TrackName(id: 30, title: "Song", artist: nil, album: nil, genre: nil),
    ]
    let items = goToItems(names)
    #expect(items.map(\.key) == ["track:31", "track:30"])
    #expect(items.map(\.detail) == ["A — B", ""])
    #expect(items.map { goToTrackID($0.key) } == [31, 30])
    #expect(goToTrackID("track:0:31") == nil)
    #expect(goToTrackID("artist:31") == nil)
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
