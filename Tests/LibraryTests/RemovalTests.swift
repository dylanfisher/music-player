import Foundation
import Testing

@testable import Library

@Test func aRemovedTrackStaysOutOfRescansUntilRestoredAndKeepsItsStats() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let path = library.path(file)
    let id = try #require(try index.track(path: path)).id
    try index.setRating(4, trackIDs: [id])
    let count = try index.trackCount()

    try index.removeFromLibrary(trackIDs: [id])
    #expect(try index.track(path: path) == nil)
    let rescan = try library.scan()
    #expect(rescan.read == 0)
    #expect(try index.track(path: path) == nil)
    #expect(try index.trackCount() == count - 1)
    // It didn't leave, so its rating isn't offered to another track.
    #expect(try index.lostFiles().isEmpty)
    #expect(try index.healthReport()[.removed].lines == [path])

    #expect(try index.restoreRemoved([id]) == [path])
    _ = try library.scan()
    let row = try #require(try index.rows(ids: [id]).first)
    #expect(row.path == path)
    #expect(row.rating == 4)
    #expect(try index.healthReport()[.removed].count == 0)
}

@Test func aTrashedTrackIsntLostAndComesBackWhenPutBack() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let path = library.path(file)
    let id = try #require(try index.track(path: path)).id
    try index.setRating(2, trackIDs: [id])
    // The test's own copy of the file stands in for the Trash.
    let trash = FileManager.default.temporaryDirectory
        .appendingPathComponent("trash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let trashed = trash.appendingPathComponent("trashed").path
    try FileManager.default.moveItem(atPath: path, toPath: trashed)

    try index.forgetTrashed(trackIDs: [id])
    #expect(try index.track(path: path) == nil)
    _ = try library.scan()
    #expect(try index.lostFiles().isEmpty)
    #expect(try index.healthReport()[.removed].count == 0)

    try FileManager.default.moveItem(atPath: trashed, toPath: path)
    _ = try library.scan()
    #expect(try index.rows(ids: [id]).first?.rating == 2)
}
