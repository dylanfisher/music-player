import Foundation
import Testing

@testable import Library
@testable import Settings

/// The share every simulated machine plays, mounted at a path of its own.
private let share = "smb://nas/music"
/// The watched folder inside it.
private let folderInShare = "library"
/// The sync folder's name in the config, as `sync_state` records it.
private let folderName = "sync"

/// A temporary folder standing in for the NAS: the sync folder and each machine's mount.
private final class SimulatedNAS {
    let root: URL
    var syncFolder: String { root.appendingPathComponent("sync").path }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: root.appendingPathComponent("sync").path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The log of the machine `id`.
    func log(_ id: String) -> String { syncFolder + "/" + syncLogName(id) }
}

/// One Mac: its own library database, the share mounted at `mount`, and a wall clock the
/// test sets.
private final class Machine {
    let index: LibraryIndex
    let databaseURL: URL
    let mount: String
    let nas: SimulatedNAS
    var nowMs: Int64 = 1_800_000_000_000

    init(_ nas: SimulatedNAS, mount: String) throws {
        self.nas = nas
        self.mount = mount
        let home = nas.root.appendingPathComponent("home-\(UUID().uuidString)")
        databaseURL = home.appendingPathComponent("library.sqlite")
        index = try LibraryIndex(at: databaseURL)
        index.wallClockMs = { [unowned self] in nowMs }
        _ = try index.locate(
            [WatchedFolder(path: folderInShare, share: share, kind: .network)],
            among: [MountedShare(url: share, mountPoint: mount)])
    }

    var id: String { get throws { try index.machineID() } }

    /// The absolute path of `name` in the library here.
    func path(_ name: String) -> String { mount + "/" + folderInShare + "/" + name }

    @discardableResult
    func sync(pushOnly: Bool = false) throws -> SyncReport {
        try index.sync(folder: folderName, at: nas.syncFolder, pushOnly: pushOnly)
    }

    /// Stores a scanned track at `name`, as a scan of the share would.
    @discardableResult
    func scanned(_ name: String, seconds: Double = 200) throws -> Int64 {
        try index.store([Crafted(path: path(name), title: name, seconds: seconds).scanned])
        return try #require(try index.track(path: path(name))).id
    }

    func track(_ name: String) throws -> TrackRow? { try index.track(path: path(name)) }

    func history(_ name: String) throws -> Int {
        try index.database.prepare(
            "SELECT count(*) FROM history h JOIN paths p ON p.id = h.path_id WHERE p.path = ?"
        ).map(path(name).precomposedStringWithCanonicalMapping) { try $0.int(0) }[0]
    }

    func playlists() throws -> [String] { try index.playlists().map(\.name) }

    func entries(of playlist: String) throws -> [String] {
        let id = try #require(try index.playlists().first { $0.name == playlist }).id
        let paths = try index.playedTracks(ids: try index.playlistTrackIDs(id))
        return try index.playlistTrackIDs(id).map {
            String(try #require(paths[$0]).path.dropFirst(path("").count))
        }
    }
}

private func machines(_ count: Int, _ nas: SimulatedNAS) throws -> [Machine] {
    try (0..<count).map { try Machine(nas, mount: nas.root.path + "/Volumes/music-\($0)") }
}

/// Syncs every machine twice, so each has read every other's log.
private func syncAll(_ machines: [Machine]) throws {
    for _ in 0..<2 {
        for machine in machines { try machine.sync() }
    }
}

@Test func aPlayAndARatingReachTheOtherMachineOnceAtItsOwnMountPoint() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let id = try a.scanned("x.flac")
    try b.scanned("x.flac")
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.index.setRating(4, trackIDs: [id])
    #expect(try a.sync().pushed >= 3)
    let report = try b.sync()
    #expect(report.problems.isEmpty)
    #expect(report.changed)
    let track = try #require(try b.track("x.flac"))
    #expect(track.playCount == 1)
    #expect(track.rating == 4)
    #expect(try b.history("x.flac") == 1)
    // Read again, nothing counts twice; and B logs nothing of what it merged, so A gets only
    // the Date Added of B's scan.
    #expect(try b.sync().applied == 0)
    #expect(try b.track("x.flac")?.playCount == 1)
    #expect(try a.sync().applied == 1)
    #expect(try a.sync().applied == 0)
    #expect(try a.track("x.flac")?.playCount == 1)
}

@Test func interleavedPlaysAreAUnionAndConflictingRatingsTakeTheLatest() throws {
    let nas = try SimulatedNAS()
    let all = try machines(3, nas)
    var ids: [Int64] = []
    for machine in all { ids.append(try machine.scanned("x.flac")) }
    for (round, machine) in all.enumerated() {
        try machine.index.recordPlay(machine.path("x.flac"), at: 1_700_000_000 + Double(round))
        machine.nowMs += Int64(round) * 1000
        try machine.index.setRating(round + 1, trackIDs: [ids[round]])
    }
    try all[0].sync()
    try all[1].index.recordPlay(all[1].path("x.flac"), at: 1_700_000_100)
    try syncAll(all)
    for machine in all {
        let track = try #require(try machine.track("x.flac"))
        #expect(track.playCount == 4)
        #expect(try machine.history("x.flac") == 4)
        // The third machine's clock was latest.
        #expect(track.rating == 3)
    }
}

@Test func aTieOnTheClockGoesToTheHigherMachineID() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try a.index.setRating(2, trackIDs: [try a.scanned("x.flac")])
    try b.index.setRating(5, trackIDs: [try b.scanned("x.flac")])
    try syncAll([a, b])
    let expected = try a.id > b.id ? 2 : 5
    #expect(try a.track("x.flac")?.rating == expected)
    #expect(try b.track("x.flac")?.rating == expected)
}

@Test func aClockFarAheadWinsOnlyWhatItTouchedAndCantDragTheOthers() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let year: Int64 = 365 * 86_400_000
    b.nowMs += year
    try a.index.setRating(1, trackIDs: [try a.scanned("x.flac")])
    try b.index.setRating(5, trackIDs: [try b.scanned("x.flac")])
    try b.sync()
    let report = try a.sync()
    #expect(report.problems.contains { $0.contains("seconds ahead of this Mac's") })
    #expect(try a.track("x.flac")?.rating == 5)
    // A rates it again after seeing B's: the later edit wins everywhere.
    a.nowMs += 60_000
    try a.index.setRating(3, trackIDs: [try #require(try a.track("x.flac")).id])
    try syncAll([a, b])
    #expect(try a.track("x.flac")?.rating == 3)
    #expect(try b.track("x.flac")?.rating == 3)
    // A's clock moved at most the skew bound past its wall time for anything else.
    let state = try a.index.database.prepare("SELECT clock_ms FROM sync_state").map {
        try $0.int64(0)
    }[0]
    #expect(state <= a.nowMs + SyncClock.skewBoundMs)
    try a.index.setRating(2, trackIDs: [try a.scanned("y.flac")])
    try b.index.setRating(4, trackIDs: [try b.scanned("y.flac")])
    try syncAll([a, b])
    // On a field neither saw the other's, B's clock still wins: it was the concurrent edit.
    #expect(try a.track("y.flac")?.rating == 4)
}

@Test func aPlaylistMadeOnOneMachineAndRenamedOnAnotherReachesAThird() throws {
    let nas = try SimulatedNAS()
    let all = try machines(3, nas)
    let (a, b, c) = (all[0], all[1], all[2])
    for machine in all {
        try machine.scanned("x.flac")
        try machine.scanned("y.flac")
    }
    let id = try a.index.createPlaylist(named: "Mix")
    _ = try a.index.addToPlaylist(
        id,
        trackIDs: [try #require(try a.track("y.flac")).id, try #require(try a.track("x.flac")).id])
    try a.sync()
    try b.sync()
    let onB = try #require(try b.index.playlists().first { $0.name == "Mix" }).id
    b.nowMs += 1000
    try b.index.renamePlaylist(onB, to: "Mix 2")
    try b.sync()
    // C reads both logs in one pass, in clock order, whichever name sorts first.
    #expect(try c.sync().problems.isEmpty)
    #expect(try c.playlists() == ["Mix 2"])
    #expect(try c.entries(of: "Mix 2") == ["y.flac", "x.flac"])
    try syncAll(all)
    for machine in all { #expect(try machine.playlists() == ["Mix 2"]) }
}

@Test func playlistEntriesTakeTheLatestWholeListAndADeleteWins() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    for machine in [a, b] {
        for name in ["x.flac", "y.flac", "z.flac"] { try machine.scanned(name) }
    }
    let onA = try a.index.createPlaylist(named: "Mix")
    _ = try a.index.addToPlaylist(onA, trackIDs: [try #require(try a.track("x.flac")).id])
    try syncAll([a, b])
    let onB = try #require(try b.index.playlists().first).id
    _ = try a.index.addToPlaylist(onA, trackIDs: [try #require(try a.track("y.flac")).id])
    b.nowMs += 1000
    _ = try b.index.addToPlaylist(onB, trackIDs: [try #require(try b.track("z.flac")).id])
    try syncAll([a, b])
    #expect(try a.entries(of: "Mix") == ["x.flac", "z.flac"])
    #expect(try b.entries(of: "Mix") == ["x.flac", "z.flac"])
    try b.index.deletePlaylist(onB)
    a.nowMs += 5000
    try a.index.renamePlaylist(onA, to: "Kept?")
    try syncAll([a, b])
    #expect(try a.playlists().isEmpty)
    #expect(try b.playlists().isEmpty)
}

@Test func aSmartPlaylistsRulesSync() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let rules = SmartRules(match: .all, rules: [])
    let id = try a.index.createPlaylist(named: "Smart", rules: rules)
    try a.index.setRules(SmartRules(match: .any, rules: []), of: id)
    try syncAll([a, b])
    let playlist = try #require(try b.index.playlists().first)
    #expect(playlist.kind == .smart(SmartRules(match: .any, rules: [])))
}

@Test func aMoveReachesAMachineThatHadTheOldPath() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let old = try a.scanned("Album/x.flac")
    try b.scanned("Album/x.flac")
    try a.index.recordPlay(a.path("Album/x.flac"), at: 1_700_000_000)
    try syncAll([a, b])
    // A's scan finds the file moved; B hasn't scanned since.
    try a.index.remove([old])
    try a.scanned("Renamed/x.flac")
    #expect(try a.index.matchMoves().count == 1)
    try syncAll([a, b])
    // B's row for the old path now has the new one, with its stats, until B's scan reads it.
    let path = try b.index.database.prepare("SELECT path FROM paths WHERE id = ?").map(
        try #require(try b.track("Album/x.flac")).id
    ) { try $0.text(0) }
    #expect(path == [b.path("Renamed/x.flac").precomposedStringWithCanonicalMapping])
    try b.index.remove([try #require(try b.track("Album/x.flac")).id])
    try b.scanned("Renamed/x.flac")
    #expect(try b.track("Renamed/x.flac")?.playCount == 1)
    #expect(try b.index.lostFiles().isEmpty)
}

@Test func aMoveAfterTheNewPathWasPlayedMergesTheStats() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let old = try a.scanned("x.flac")
    let rated = try a.index.track(path: a.path("x.flac"))!.id
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.index.setRating(4, trackIDs: [rated])
    try a.index.toggleLoved(trackIDs: [rated])
    let playlist = try a.index.createPlaylist(named: "Mix")
    _ = try a.index.addToPlaylist(playlist, trackIDs: [rated])
    try a.index.remove([old])
    try a.scanned("renamed.flac")
    #expect(try a.index.matchMoves().count == 1)
    // B scanned after the move, so it only has the new path, and played it.
    try b.scanned("renamed.flac")
    try b.index.recordPlay(b.path("renamed.flac"), at: 1_700_000_500)
    try a.sync()
    #expect(try b.sync().problems.isEmpty)
    let track = try #require(try b.track("renamed.flac"))
    #expect(track.playCount == 2)
    #expect(try b.history("renamed.flac") == 2)
    #expect(track.rating == 4)
    #expect(track.loved)
    #expect(try b.entries(of: "Mix") == ["renamed.flac"])
    #expect(try b.index.lostFiles().isEmpty)
    // B's play reaches A, which already made the move.
    try a.sync()
    #expect(try a.track("renamed.flac")?.playCount == 2)
}

@Test func aDecomposedNameOnOneMachineIsThePrecomposedOneOnAnother() throws {
    let nas = try SimulatedNAS()
    let all = try machines(2, nas)
    let decomposed = "Cafe\u{301}/Ame\u{301}lie.flac"
    let precomposed = "Caf\u{e9}/Am\u{e9}lie.flac"
    try all[0].index.recordPlay(all[0].path(decomposed), at: 1_700_000_000)
    try all[1].scanned(precomposed)
    try syncAll(all)
    #expect(try all[1].track(precomposed)?.playCount == 1)
}

@Test func aLogEndingMidLineIsReadToItsLastCompleteLine() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try b.scanned("x.flac")
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.sync()
    let log = nas.log(try a.id)
    let whole = try Data(contentsOf: URL(fileURLWithPath: log))
    // A second line, cut short as if A died while writing it.
    let line = SyncRecord(
        seq: 2, clock: SyncClock(ms: 1_800_000_001_000, counter: 0),
        event: .play(path: "music/library/x.flac", at: 1_700_000_100)
    ).line
    try (whole + Data(line.utf8.prefix(20))).write(to: URL(fileURLWithPath: log))
    #expect(try b.sync().problems.isEmpty)
    #expect(try b.track("x.flac")?.playCount == 1)
    try (whole + Data((line + "\n").utf8)).write(to: URL(fileURLWithPath: log))
    try b.sync()
    #expect(try b.track("x.flac")?.playCount == 2)
}

@Test func withTheFolderAwayEventsWaitAndGoOutWhenItsBack() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try b.scanned("x.flac")
    try FileManager.default.removeItem(atPath: nas.syncFolder)
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    #expect(throws: SyncFileError.self) { try a.sync() }
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_100)
    try FileManager.default.createDirectory(
        atPath: nas.syncFolder, withIntermediateDirectories: true)
    #expect(try a.sync().pushed == 2)
    try b.sync()
    #expect(try b.track("x.flac")?.playCount == 2)
}

@Test func aPushThatDiedMidLineCarriesOnFromWhereItStopped() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try b.scanned("x.flac")
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.sync()
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_100)
    // The bytes of the second line reached the file, half of them, but not the record of it.
    let line = try a.index.database.prepare("SELECT line FROM sync_outbox WHERE seq = 2").map {
        try $0.text(0)
    }[0]
    let handle = try #require(FileHandle(forWritingAtPath: nas.log(try a.id)))
    handle.seekToEndOfFile()
    handle.write(Data(line.utf8.prefix(10)))
    handle.closeFile()
    #expect(try a.sync().pushed == 1)
    #expect(try b.sync().problems.isEmpty)
    #expect(try b.track("x.flac")?.playCount == 2)
}

@Test func aLogSomeoneElseWroteIsntWrittenAgain() throws {
    let nas = try SimulatedNAS()
    let a = try machines(1, nas)[0]
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.sync()
    try Data("{}\n".utf8).write(to: URL(fileURLWithPath: nas.log(try a.id)))
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_100)
    #expect(throws: SyncFileError.self) { try a.sync() }
}

@Test func anImportReachesTheOtherMachinesAsEvents() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try a.scanned("x.flac")
    try b.scanned("x.flac")
    var library = PlayerLibrary(player: .swinsian, source: "/tmp/swinsian.sqlite")
    var track = PlayerTrack(path: a.path("x.flac"))
    track.plays = 7
    track.skips = 2
    track.rating = 3
    track.loved = true
    track.addedSeconds = 1_000_000_000
    track.lastPlayedSeconds = 1_600_000_000
    library.tracks = [track]
    _ = try a.index.applyImport(library, prefix: nil)
    try syncAll([a, b])
    let synced = try #require(try b.track("x.flac"))
    #expect(synced.playCount == 7)
    #expect(synced.skipCount == 2)
    #expect(synced.rating == 3)
    #expect(synced.loved)
    #expect(synced.addedSeconds == 1_000_000_000)
    #expect(synced.lastPlayedSeconds == 1_600_000_000)
}

@Test func dateAddedIsTheEarliestAnyMachineSaw() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try a.scanned("x.flac")
    let first = try #require(try a.track("x.flac")).addedSeconds
    Thread.sleep(forTimeInterval: 0.01)
    try b.scanned("x.flac")
    try syncAll([a, b])
    #expect(try b.track("x.flac")?.addedSeconds == first)
    #expect(try a.track("x.flac")?.addedSeconds == first)
}

@Test func aPathOutsideThisMachinesFoldersIsCountedNotKept() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.sync()
    // B watches another share only.
    _ = try b.index.locate(
        [WatchedFolder(path: "other", share: "smb://nas/elsewhere", kind: .network)],
        among: [MountedShare(url: "smb://nas/elsewhere", mountPoint: b.mount + "-other")])
    try b.index.database.execute("DELETE FROM share_roots WHERE share = '\(share)'")
    let report = try b.sync()
    #expect(report.outside == 1)
    #expect(try b.index.database.prepare("SELECT count(*) FROM plays").map { try $0.int(0) } == [0])
}

@Test func discardedStatsStartANewLogAndComeBackFromTheOldOne() throws {
    let nas = try SimulatedNAS()
    let a = try machines(1, nas)[0]
    try a.scanned("x.flac")
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.sync()
    let before = try a.id
    for part in ["stats", "sync"] {
        try a.index.database.execute(
            "UPDATE schema_identity SET sql = 'older' WHERE part = '\(part)'")
        let reopened = try LibraryIndex(at: a.databaseURL)
        _ = try reopened.locate(
            [WatchedFolder(path: folderInShare, share: share, kind: .network)],
            among: [MountedShare(url: share, mountPoint: a.mount)])
        #expect(try reopened.machineID() != before)
        #expect(try reopened.index(isEmptyAt: a.path("x.flac")))
        _ = try reopened.sync(folder: folderName, at: nas.syncFolder)
        let plays = try reopened.database.prepare("SELECT play_count FROM plays").map {
            try $0.int(0)
        }
        #expect(plays == [1], "\(part)")
    }
}

private extension LibraryIndex {
    func index(isEmptyAt path: String) throws -> Bool {
        try database.prepare("SELECT count(*) FROM plays").map { try $0.int(0) } == [0]
    }
}

private extension Array where Element == Machine {
    var pair: (Machine, Machine) { (self[0], self[1]) }
}
