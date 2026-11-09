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

@MainActor @Test func goToItemsListingIsKeptUntilTheLibraryChanges() async throws {
    var builds = 0
    let listing = LibraryListing<Int> {
        builds += 1
        return builds
    }
    #expect(listing.value == nil)
    #expect(try await listing.current() == 1)
    #expect(try await listing.current() == 1)
    #expect(listing.value == 1)
    #expect(builds == 1)
    listing.libraryChanged()
    #expect(listing.value == nil)
    #expect(try await listing.current() == 2)
    #expect(builds == 2)
}

@MainActor @Test func aListingTheLibraryChangedUnderIsNotKept() async throws {
    struct Unreadable: Error {}
    var builds = 0
    var listing: LibraryListing<Int>?
    listing = LibraryListing {
        builds += 1
        if builds == 1 { listing?.libraryChanged() }
        if builds == 2 { throw Unreadable() }
        return builds
    }
    #expect(try await listing?.current() == 1)
    #expect(listing?.value == nil)
    await #expect(throws: Unreadable.self) { try await listing?.current() }
    // A failed build is tried again.
    #expect(try await listing?.current() == 3)
    #expect(listing?.value == 3)
}

@Test func showAllMusicIsListedOnlyWhenItWouldChangeTheTable() {
    let items = [
        PaletteItem(kind: .command, key: showAllMusicKey, title: "Show All Music"),
        PaletteItem(kind: .command, key: "command:view.other", title: "Other"),
    ]
    #expect(paletteCommands(items, showsAllMusic: false).map(\.key) == items.map(\.key))
    #expect(paletteCommands(items, showsAllMusic: true).map(\.key) == ["command:view.other"])
    #expect(showAllMusicKey == "command:view.showAllTracks")
}

/// What users type before a colon, and the keys frecency saved, spelled once by the palette's
/// kinds; the command line's play prefixes are the same.
@Test func thePaletteKindsKeepTheirNamesAndThePlayPrefixesMatch() {
    #expect(
        PaletteItem.Kind.allCases.map(\.name) == [
            "command", "setting", "output", "playlist", "genre", "artist", "album", "track",
        ])
    let kinds: [BrowserModel.Pane: PaletteItem.Kind] = [
        .genre: .genre, .artist: .artist, .album: .album,
    ]
    for pane in BrowserModel.Pane.allCases {
        #expect(pane.keyPrefix == kinds[pane]?.keyPrefix)
    }
    #expect(showAllMusicKey == "command:view.showAllTracks")
}
