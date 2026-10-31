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
    let queen = LibraryKey.album("Greatest Hits", by: "Queen")
    #expect(
        items.map(\.key) == ["artist:Abba", LibraryKey.album("Greatest Hits", by: "Abba"), queen])
    #expect(Set(items.map(\.key)).count == 3)
    #expect(items.map(\.detail) == ["Artist", "Album — Abba", "Album — Queen"])
    #expect(shown[queen]?.1 == 8)
}
