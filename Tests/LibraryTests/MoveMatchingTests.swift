import Foundation
import Testing

@testable import Library
@testable import Metadata
@testable import Settings

/// The library's first readable fixture file, played once and rated, then moved on disk to
/// `destination` (relative to the root), and the ID and Date Added it had.
private func playedThenMoved(_ library: TestLibrary, to destination: String) throws -> (
    id: Int64, added: Double, from: String, to: String
) {
    _ = try library.scan()
    let index = try library.index()
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let from = library.path(file)
    let before = try #require(try index.track(path: from))
    try index.recordPlay(from, at: 1000)
    try index.setRating(4, trackIDs: [before.id])
    let to = library.root + "/" + destination
    try FileManager.default.createDirectory(
        atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: from, toPath: to)
    return (before.id, before.addedSeconds, from, to)
}

@Test func aRenamedFileKeepsItsIDAndStats() throws {
    let library = try TestLibrary()
    let file = try playedThenMoved(library, to: "renamed.flac")
    let summary = try library.scan()
    #expect(summary.moved == 1)
    let index = try library.index()
    #expect(try index.track(path: file.from) == nil)
    let after = try #require(try index.track(path: file.to))
    #expect(after.id == file.id)
    #expect(after.addedSeconds == file.added)
    #expect(after.playCount == 1)
    #expect(after.rating == 4)
    #expect(try index.lostFiles().isEmpty)
    // The scan's row for the new path is gone, so the path has one ID.
    let rows = try index.database.prepare("SELECT count(*) FROM paths WHERE path = ?").map(
        file.to.precomposedStringWithCanonicalMapping
    ) { try $0.int(0) }
    #expect(rows == [1])
}

@Test func aFileMovedToAnotherFolderKeepsItsStats() throws {
    let library = try TestLibrary()
    let file = try playedThenMoved(library, to: "Elsewhere/Deeper/moved.flac")
    #expect(try library.scan().moved == 1)
    let after = try #require(try library.index().track(path: file.to))
    #expect(after.id == file.id)
    #expect(after.playCount == 1)
}

@Test func aMoveSeenByTwoScansStillMatches() throws {
    let library = try TestLibrary()
    let file = try playedThenMoved(library, to: "Elsewhere/moved.flac")
    let folder = (file.from as NSString).deletingLastPathComponent
    // The old folder's scan finds the file gone; the new folder's, in a later scan, finds it.
    #expect(try library.scan(only: [folder]).moved == 0)
    #expect(try library.index().lostFiles().map(\.id) == [file.id])
    #expect(try library.scan(only: [library.root + "/Elsewhere"]).moved == 1)
    #expect(try library.index().track(path: file.to)?.id == file.id)
}

@Test func aMovedTrackIsFoundBySearchUnderItsKeptID() throws {
    let library = try TestLibrary()
    let file = try playedThenMoved(library, to: "renamed.flac")
    _ = try library.scan()
    let index = try library.index()
    let title = try #require(try index.track(path: file.to)).title
    let found = try index.trackIDs(
        TrackFilter(search: title), sortedBy: .title, ascending: true)
    #expect(found.contains(file.id))
}

private func gone(_ track: Crafted, in index: LibraryIndex) throws -> Int64 {
    try index.store([track.scanned])
    let id = try #require(try index.track(path: track.path)).id
    try index.recordPlay(track.path, at: 100)
    try index.remove([id])
    return id
}

@Test func aMoveWithARetagMatchesOnItsAudio() throws {
    let index = try craftedIndex([])
    let old = try gone(Crafted(path: "/M/a.flac", title: "Old Title", seconds: 123), in: index)
    try index.store([Crafted(path: "/M/b.flac", title: "New Title", seconds: 123).scanned])
    let moves = try index.matchMoves()
    #expect(moves == [TrackMove(from: "/M/a.flac", to: "/M/b.flac")])
    let after = try #require(try index.track(path: "/M/b.flac"))
    #expect(after.id == old)
    #expect(after.title == "New Title")
    #expect(after.playCount == 1)
}

@Test func anOlderTrackAloneInItsLengthTakesTheStats() throws {
    let index = try craftedIndex([Crafted(path: "/M/old.flac", seconds: 50).scanned])
    let id = try gone(Crafted(path: "/M/a.flac", seconds: 50), in: index)
    #expect(try index.matchMoves().count == 1)
    #expect(try index.track(path: "/M/old.flac")?.id == id)
}

@Test func aTrackSharingItsLengthWithAnotherIsntGuessed() throws {
    let index = try craftedIndex([
        Crafted(path: "/M/x.flac", title: "X", seconds: 50).scanned,
        Crafted(path: "/M/y.flac", title: "Y", seconds: 50).scanned,
    ])
    _ = try gone(Crafted(path: "/M/a.flac", title: "A", seconds: 50), in: index)
    #expect(try index.matchMoves().isEmpty)
    #expect(
        try index.lostFiles().map(\.candidates) == [try ids(index, ["/M/x.flac", "/M/y.flac"])])
}

@Test func aFileThatArrivesBeforeItsOldPathLeavesStillMatches() throws {
    let library = try TestLibrary()
    let file = try playedThenMoved(library, to: "Elsewhere/moved.flac")
    // The new folder's scan finds it first; the old folder's, later, finds it gone.
    #expect(try library.scan(only: [library.root + "/Elsewhere"]).moved == 0)
    #expect(try library.scan(only: [(file.from as NSString).deletingLastPathComponent]).moved == 1)
    #expect(try library.index().track(path: file.to)?.id == file.id)
}

@Test func aTitleBreaksATieBetweenFilesOfOneLength() throws {
    let index = try craftedIndex([])
    let one = try gone(Crafted(path: "/M/1.flac", title: "One", seconds: 60), in: index)
    let two = try gone(Crafted(path: "/M/2.flac", title: "Two", seconds: 60), in: index)
    try index.store([
        Crafted(path: "/N/two.flac", title: "Two", seconds: 60).scanned,
        Crafted(path: "/N/one.flac", title: "One", seconds: 60).scanned,
    ])
    #expect(try index.matchMoves().count == 2)
    #expect(try index.track(path: "/N/one.flac")?.id == one)
    #expect(try index.track(path: "/N/two.flac")?.id == two)
}

@Test func twoGoneFilesOfOneLengthWaitInLostStats() throws {
    let index = try craftedIndex([])
    let one = try gone(Crafted(path: "/M/1.flac", title: "Song", seconds: 60), in: index)
    let two = try gone(Crafted(path: "/M/2.flac", title: "Song", seconds: 60), in: index)
    try index.store([Crafted(path: "/N/new.flac", title: "Retitled", seconds: 60).scanned])
    #expect(try index.matchMoves().isEmpty)

    let new = try #require(try index.track(path: "/N/new.flac")).id
    #expect(
        try index.lostFiles() == [
            LostFile(id: one, path: "/M/1.flac", candidates: [new], matching: 1),
            LostFile(id: two, path: "/M/2.flac", candidates: [new], matching: 1),
        ])
    let findings = try index.healthReport(measuredChecks: { _ in [] })[.lostStats]
    #expect(findings.trackIDs == [new])
    #expect(findings.lines == ["/M/1.flac: matching tracks: 1", "/M/2.flac: matching tracks: 1"])
    #expect(findings.pathIDs == [one, two])

    // The user picks the first; the track now has stats, so the second has no candidate left.
    #expect(try index.moveStats(from: one, to: new))
    let picked = try #require(try index.track(path: "/N/new.flac"))
    #expect(picked.id == one)
    #expect(picked.playCount == 1)
    #expect(
        try index.lostFiles() == [LostFile(id: two, path: "/M/2.flac", candidates: [], matching: 0)]
    )
    // A stale pick: the track has stats now. Nothing changes.
    #expect(try index.moveStats(from: two, to: one) == false)
    #expect(try index.track(path: "/N/new.flac")?.id == one)

    try index.dismissLost([two])
    #expect(try index.lostFiles().isEmpty)
    #expect(try index.healthReport(measuredChecks: { _ in [] })[.lostStats].count == 0)
}

@Test func aDismissedPathIsLostAgainAfterItsFileIsRead() throws {
    let index = try craftedIndex([])
    let id = try gone(Crafted(path: "/M/a.flac", seconds: 70), in: index)
    try index.dismissLost([id])
    try index.store([Crafted(path: "/M/a.flac", seconds: 70).scanned])
    try index.remove([id])
    #expect(try index.lostFiles().map(\.id) == [id])
}

@Test func aPathWithoutStatsIsNeverLost() throws {
    let index = try craftedIndex([Crafted(path: "/M/a.flac").scanned])
    try index.remove(try ids(index, ["/M/a.flac"]))
    #expect(try index.lostFiles().isEmpty)
}

@Test func decomposedAndPrecomposedNamesAreOnePath() throws {
    let precomposed = "/M/Caf\u{e9}.flac"
    let decomposed = precomposed.decomposedStringWithCanonicalMapping
    #expect(Array(precomposed.utf8) != Array(decomposed.utf8))
    let index = try craftedIndex([Crafted(path: decomposed).scanned])
    let id = try #require(try index.track(path: decomposed)).id
    // A play under the other spelling counts for the same path.
    try index.recordPlay(precomposed, at: 100)
    #expect(try index.track(path: decomposed)?.playCount == 1)

    // The file leaves and comes back spelled the other way: same ID, same stats.
    try index.remove([id])
    try index.store([Crafted(path: precomposed).scanned])
    let back = try #require(try index.track(path: precomposed))
    #expect(back.id == id)
    #expect(back.playCount == 1)
    let stored = try index.database.prepare("SELECT path FROM paths").map { try $0.text(0) }
    #expect(stored.map { Array($0.utf8) } == [Array(precomposed.utf8)])
}

@Test func movePairsAreOneToOne() {
    func path(_ id: Int64, _ frames: Int, _ title: String?) -> MovablePath {
        MovablePath(
            id: id, path: "/\(id)",
            audio: AudioFacts(codec: "flac", sampleRateHz: 1, frames: frames),
            title: title)
    }
    let pairs = movePairs(
        gone: [path(1, 10, "A"), path(2, 20, "B"), path(3, 20, "B"), path(4, 30, nil)],
        free: [path(5, 10, "Z"), path(6, 20, "B"), path(7, 30, nil), path(8, 40, "A")])
    // 1 and 5 are alone at 10 frames; 2 and 3 tie on title too; 4 and 7 are alone at 30.
    #expect(pairs.map { [$0.0.id, $0.1.id] } == [[1, 5], [4, 7]])
}

@Test func aLosslessFileConvertedToAnotherLosslessCodecKeepsItsStats() throws {
    let index = try craftedIndex([])
    let old = try gone(Crafted(path: "/M/a.m4a", seconds: 61, codec: .alac), in: index)
    try index.store([Crafted(path: "/M/a.flac", seconds: 61).scanned])
    #expect(try index.matchMoves() == [TrackMove(from: "/M/a.m4a", to: "/M/a.flac")])
    #expect(try index.track(path: "/M/a.flac")?.id == old)
}

@Test func aLossyFileIsNeverTheSameAudioAsALosslessOne() throws {
    let index = try craftedIndex([])
    _ = try gone(Crafted(path: "/M/a.m4a", seconds: 61, codec: .aac), in: index)
    try index.store([Crafted(path: "/M/a.flac", seconds: 61).scanned])
    #expect(try index.matchMoves().isEmpty)
}

@Test func aPathChangedOnlyInItsExtensionBreaksATie() throws {
    let index = try craftedIndex([])
    let one = try gone(
        Crafted(path: "/M/1.m4a", title: "Song", seconds: 60, codec: .alac), in: index)
    let two = try gone(
        Crafted(path: "/M/2.m4a", title: "Song", seconds: 60, codec: .alac), in: index)
    try index.store([
        Crafted(path: "/M/2.flac", title: "Song", seconds: 60).scanned,
        Crafted(path: "/M/1.flac", title: "Song", seconds: 60).scanned,
    ])
    #expect(try index.matchMoves().count == 2)
    #expect(try index.track(path: "/M/1.flac")?.id == one)
    #expect(try index.track(path: "/M/2.flac")?.id == two)
}

@Test func aLostFileOffersAtMostSoManyTracks() throws {
    let count = lostCandidatesListed + 2
    let index = try craftedIndex(
        (0..<count).map { Crafted(path: "/N/\($0).flac", seconds: 9).scanned })
    _ = try gone(Crafted(path: "/M/a.flac", seconds: 9), in: index)
    let lost = try #require(try index.lostFiles().first)
    #expect(lost.candidates.count == lostCandidatesListed)
    #expect(lost.matching == count)
}
