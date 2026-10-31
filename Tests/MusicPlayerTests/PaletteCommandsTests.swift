import Library
import LibraryBrowser
import Palette
import Testing

@testable import MusicPlayer

@Test func sameTitledAlbumsAreEachListedWithTheirArtist() {
    let (items, shown) = libraryItems([
        (.artist, BrowserEntry(id: 1, name: "Abba")),
        (.album, BrowserEntry(id: 7, name: "Greatest Hits", artist: "Abba")),
        (.album, BrowserEntry(id: 8, name: "Greatest Hits", artist: "Queen")),
    ])
    #expect(items.map(\.key) == ["artist:Abba", "album:7", "album:8"])
    #expect(items.map(\.detail) == ["Artist", "Album — Abba", "Album — Queen"])
    #expect(shown["album:8"]?.1 == 8)
    // A play counts toward the album by the same key the listing uses.
    #expect(LibraryKey.album(8) == "album:8")
}
