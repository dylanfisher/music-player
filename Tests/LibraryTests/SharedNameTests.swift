import Foundation
import Testing

@testable import Library
@testable import Settings

private let share = "smb://nas/music"

/// A Mac's library with the share's `library` folder mounted under `mount`.
private func library(mount: String) throws -> LibraryIndex {
    let index = try LibraryIndex(
        at: FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-names-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite"))
    _ = try index.locate(
        [WatchedFolder(path: "library", share: share, kind: .network)],
        among: [MountedShare(url: share, mountPoint: mount)])
    return index
}

@Test func aTrackOnTheShareIsFoundOnAMacThatMountsItElsewhere() throws {
    let first = try library(mount: "/Volumes/music")
    let second = try library(mount: "/Volumes/music-1")
    let name = "Artist/Album/01 One.flac"
    try first.store([Crafted(path: "/Volumes/music/library/" + name).scanned])
    try second.store([Crafted(path: "/Volumes/music-1/library/" + name).scanned])
    let id = try #require(try first.track(path: "/Volumes/music/library/" + name)).id

    let shared = try #require(try first.sharedName(ofTrack: id))
    #expect(shared == "music/library/" + name)
    let found = try #require(try second.trackID(sharedName: shared))
    #expect(try second.paths(ids: [found])[found] == "/Volumes/music-1/library/" + name)
}

@Test func aTrackInAFolderStoredByPathIsNamedByItsPath() throws {
    let index = try library(mount: "/Volumes/music")
    let path = "/Users/me/Music/One.flac"
    try index.store([Crafted(path: path).scanned])
    let id = try #require(try index.track(path: path)).id
    #expect(try index.sharedName(ofTrack: id) == path)
    #expect(try index.trackID(sharedName: path) == id)
    #expect(try index.trackID(sharedName: "/Users/someone/Music/One.flac") == nil)
    #expect(try index.trackID(sharedName: "music/library/Gone.flac") == nil)
}

@Test func aPlaylistIsNamedByItsSyncID() throws {
    let index = try library(mount: "/Volumes/music")
    let id = try index.createPlaylist(named: "Evening")
    let syncID = try #require(try index.syncID(ofPlaylist: id))
    #expect(try index.playlistID(syncID: syncID) == id)
    try index.deletePlaylist(id)
    #expect(try index.playlistID(syncID: syncID) == nil)
    #expect(try index.playlistID(syncID: String(repeating: "0", count: 32)) == nil)
}
