import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor
@Test func aPickedTrackIsNoLongerOfferedToTheOtherLostFiles() async throws {
    var moved: [[Int64]] = []
    var dismissed: [Int64] = []
    let session = LostStatsSession(
        lost: [
            LostFile(id: 1, path: "/M/1.flac", candidates: [10, 11], matching: 2),
            LostFile(id: 2, path: "/M/2.flac", candidates: [10], matching: 1),
            LostFile(id: 3, path: "/M/3.flac", candidates: [], matching: 0),
        ],
        paths: [10: "/N/a.flac", 11: "/N/b.flac"],
        move: {
            moved.append([$0, $1])
            return true
        }, dismiss: { dismissed += $0 })

    try await session.pick(10)
    #expect(moved == [[1, 10]])
    #expect(session.current == LostFile(id: 2, path: "/M/2.flac", candidates: [], matching: 0))
    try await session.dismissShown()
    try await session.dismissShown()
    #expect(dismissed == [2, 3])
    #expect(session.current == nil)
}

@MainActor
@Test func aFailedPickKeepsTheFileShown() async throws {
    struct Refused: Error {}
    let file = LostFile(id: 1, path: "/M/1.flac", candidates: [10], matching: 1)
    let session = LostStatsSession(
        lost: [file], paths: [:], move: { _, _ in throw Refused() }, dismiss: { _ in })
    await #expect(throws: Refused.self) { try await session.pick(10) }
    #expect(session.current == file)
}

@MainActor
@Test func aStalePickSkipsToTheNextFile() async throws {
    let session = LostStatsSession(
        lost: [
            LostFile(id: 1, path: "/M/1.flac", candidates: [10], matching: 1),
            LostFile(id: 2, path: "/M/2.flac", candidates: [10], matching: 1),
        ],
        paths: [:], move: { _, _ in false }, dismiss: { _ in })
    try await session.pick(10)
    // Nothing moved, so the track is still offered to the next file.
    #expect(session.current == LostFile(id: 2, path: "/M/2.flac", candidates: [10], matching: 1))
}
