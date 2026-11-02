import AppKit
import Testing

@testable import Library
@testable import MusicPlayer

@MainActor @Test func thePlaylistPopUpKeepsPlaylistsOfTheSameName() {
    let menu = playlistPopUp([
        Playlist(id: 4, name: "Mix", kind: .manual), Playlist(id: 9, name: "Mix", kind: .manual),
    ])
    #expect(menu.numberOfItems == 2)
    menu.selectItem(at: 1)
    #expect(menu.selectedTag() == 9)
}
