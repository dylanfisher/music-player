import Foundation
import Testing

@testable import Library

/// A library with one track, a play and a rating, whose index part this build reads as built
/// from an earlier shape, so the next open rebuilds it.
private func olderLibrary() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rescan-\(UUID().uuidString)/library.sqlite")
    let index = try LibraryIndex(at: url)
    try index.store([Crafted(path: "/m/a/1.flac", album: "A").scanned])
    try index.recordPlay("/m/a/1.flac", at: 100)
    try index.setRating(4, trackIDs: try ids(index, ["/m/a/1.flac"]))
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")
    return url
}

@Test func quitAtTheRescanQuestionLeavesTheFileAsItWas() throws {
    let url = try olderLibrary()
    let before = try Data(contentsOf: url)
    var asked: [RescanNotice] = []
    #expect(throws: LibraryError.rescanDeclined) {
        _ = try LibraryIndex(
            at: url,
            confirmRescan: {
                asked.append($0)
                return false
            })
    }
    #expect(asked.map(\.parts) == [[.index]])
    #expect(try Data(contentsOf: url) == before)

    // The next open asks again and still finds everything.
    var askedAgain = false
    #expect(throws: LibraryError.rescanDeclined) {
        _ = try LibraryIndex(
            at: url,
            confirmRescan: { _ in
                askedAgain = true
                return false
            })
    }
    #expect(askedAgain)
    let index = try LibraryIndex(at: url, confirmRescan: { _ in true })
    #expect(index.rebuiltParts == [.index, .scans])
    #expect(try index.trackCount() == 0)
    #expect(
        try index.database.prepare("SELECT count(*) FROM ratings").map { try $0.int(0) } == [1])
    #expect(try index.discards().isEmpty)
}

@Test func aRescanIsAskedOnlyOfALibraryThatHoldsTheChangedPart() throws {
    var asked = false
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rescan-\(UUID().uuidString)/library.sqlite")
    let new = try LibraryIndex(
        at: url,
        confirmRescan: { _ in
            asked = true
            return false
        })
    #expect(!asked)
    #expect(new.rebuiltParts.isEmpty)
    #expect(
        try LibraryIndex(
            at: url,
            confirmRescan: { _ in
                asked = true
                return false
            }
        )
        .rebuiltParts.isEmpty)
    #expect(!asked)

    // Without a question, an open rebuilds as before.
    let older = try olderLibrary()
    #expect(try LibraryIndex(at: older).rebuiltParts == [.index, .scans])
}

@Test func aStatsRebuildDoesntAskAndAPartARescanDoesntRefillDoesnt() throws {
    var asked = false
    let url = try olderLibrary()
    try LibraryIndex(at: url).database.execute(
        "UPDATE schema_identity SET sql = 'older' WHERE part = 'measures'")
    #expect(
        try LibraryIndex(
            at: url,
            confirmRescan: { _ in
                asked = true
                return false
            }
        )
        .rebuiltParts == [.measures])
    #expect(!asked)

    try LibraryIndex(at: url).database.execute(
        "UPDATE schema_identity SET sql = 'older' WHERE part IN ('stats', 'index')")
    let rebuilt = try LibraryIndex(
        at: url,
        confirmRescan: { _ in
            asked = true
            return false
        })
    #expect(!asked)
    #expect(rebuilt.rebuiltParts.contains(.stats))
    #expect(try rebuilt.discards().count == 1)
}

@Test func theNoticeHoldsEachRefilledPartsWhyOnce() throws {
    #expect(RescanNotice(parts: [.measures, .scans]) == nil)
    let notice = try #require(RescanNotice(parts: [.index, .scans, .index]))
    let why = try #require(SchemaPart.index.rescanWhy)
    #expect(notice.parts == [.index])
    #expect(notice.text.components(separatedBy: why).count == 2)
    #expect(notice.text.hasSuffix("Every file is read again. Plays, ratings and playlists stay."))
}
