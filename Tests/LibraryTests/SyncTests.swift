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

    /// A new Mac, or with `databaseURL` the one whose database that is, opened again.
    init(_ nas: SimulatedNAS, mount: String, databaseURL: URL? = nil) throws {
        self.nas = nas
        self.mount = mount
        self.databaseURL =
            databaseURL
            ?? nas.root.appendingPathComponent("home-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite")
        index = try LibraryIndex(at: self.databaseURL)
        index.wallClockMs = { [unowned self] in nowMs }
        _ = try index.locate(
            [WatchedFolder(path: folderInShare, share: share, kind: .network)],
            among: [MountedShare(url: share, mountPoint: mount)])
    }

    var id: String { get throws { try index.machineID() } }

    /// This Mac with its database opened again, as at the app's next launch.
    func reopened() throws -> Machine { try Machine(nas, mount: mount, databaseURL: databaseURL) }

    /// The absolute path of `name` in the library here.
    func path(_ name: String) -> String { mount + "/" + folderInShare + "/" + name }

    @discardableResult
    func sync(pushOnly: Bool = false) throws -> SyncReport {
        try index.sync(folder: folderName, at: nas.syncFolder, pushOnly: pushOnly)
    }

    /// Stores a scanned track at `name`, titled `title` or else its name, as a scan of the
    /// share would.
    @discardableResult
    func scanned(_ name: String, title: String? = nil, seconds: Double = 200) throws -> Int64 {
        try index.store([
            Crafted(path: path(name), title: title ?? name, seconds: seconds).scanned
        ])
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

@Test func theLatestOfALikeAndADislikeIsTheOpinionEverywhere() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let onA = try a.scanned("x.flac")
    let onB = try b.scanned("x.flac")
    try a.index.toggle(.liked, trackIDs: [onA])
    b.nowMs += 60_000
    try b.index.toggle(.disliked, trackIDs: [onB])
    try syncAll([a, b])
    #expect(try a.index.opinion(of: onA) == .disliked)
    #expect(try b.index.opinion(of: onB) == .disliked)
    // Clearing the dislike later clears it everywhere, without bringing back A's like.
    b.nowMs += 60_000
    try b.index.toggle(.disliked, trackIDs: [onB])
    try syncAll([a, b])
    #expect(try a.index.opinion(of: onA) == nil)
}

@Test func aNeverUpgradeMarkReachesTheOtherMacAndTheLatestWins() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try a.index.setNeverUpgrade(true, releases: [4242, 7])
    try syncAll([a, b])
    #expect(try b.index.neverUpgradeReleases() == [4242, 7])
    b.nowMs += 1000
    try b.index.setNeverUpgrade(false, releases: [4242])
    try a.index.setNeverUpgrade(true, releases: [4242])
    try syncAll([a, b])
    #expect(try a.index.neverUpgradeReleases() == [7], "B's clear was later")
    #expect(try b.index.neverUpgradeReleases() == [7])
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

@Test func anEditOfAPlaylistWaitsForItsCreateFromALogNotReadYet() throws {
    let nas = try SimulatedNAS()
    let all = try machines(3, nas)
    let (a, b, c) = (all[0], all[1], all[2])
    for machine in all { try machine.scanned("x.flac") }
    _ = try a.index.createPlaylist(named: "Mix")
    try a.sync()
    try b.sync()
    // B's clock is an hour behind, but its first edit still comes after the create.
    b.nowMs -= 3_600_000
    let onB = try #require(try b.index.playlists().first).id
    _ = try b.index.addToPlaylist(onB, trackIDs: [try #require(try b.track("x.flac")).id])
    try b.sync()
    let clocks = try [a, b].map { machine in
        try machine.index.database.prepare(
            "SELECT line FROM sync_outbox WHERE line LIKE '%playlist%' ORDER BY seq DESC LIMIT 1"
        ).map { try SyncRecord(line: Array(try $0.text(0).utf8)[...]).clock }[0]
    }
    #expect(clocks[1] > clocks[0])
    // C can't open A's log this time, so B's edit waits rather than being passed.
    let log = nas.log(try a.id)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: log)
    let first = try c.sync()
    #expect(first.problems.contains { $0.contains("can't open") })
    #expect(try c.playlists().isEmpty)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log)
    #expect(try c.sync().problems.isEmpty)
    #expect(try c.entries(of: "Mix") == ["x.flac"])
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

@Test func aMoveWaitsForTheScanOfAMachineThatStillHasTheOldFile() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let old = try a.scanned("Album/x.flac", title: "Song")
    try b.scanned("Album/x.flac", title: "Song")
    try a.index.recordPlay(a.path("Album/x.flac"), at: 1_700_000_000)
    try syncAll([a, b])
    // A's scan finds the file moved; B hasn't scanned since.
    try a.index.remove([old])
    try a.scanned("Renamed/x.flac", title: "Song")
    #expect(try a.index.matchMoves().count == 1)
    try a.sync()
    let report = try b.sync()
    #expect(report.problems.contains { $0.contains("waits for its own scan") })
    #expect(try b.track("Album/x.flac")?.playCount == 1)
    // B's scan finds the move itself, and A's move, read again, does nothing more.
    try b.index.remove([try #require(try b.track("Album/x.flac")).id])
    try b.scanned("Renamed/x.flac", title: "Song")
    #expect(try b.index.matchMoves().count == 1)
    #expect(try b.track("Renamed/x.flac")?.playCount == 1)
    #expect(try b.index.lostFiles().isEmpty)
}

@Test func aMoveOfAPathThisMachineNeverScannedTakesTheRowAlong() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let old = try a.scanned("Album/x.flac", title: "Song")
    try a.index.recordPlay(a.path("Album/x.flac"), at: 1_700_000_000)
    try syncAll([a, b])
    try a.index.remove([old])
    try a.scanned("Renamed/x.flac", title: "Song")
    #expect(try a.index.matchMoves().count == 1)
    // B never had the file, so its row for the old path, from A's play, takes the new one.
    try a.sync()
    try b.sync()
    try b.scanned("Renamed/x.flac", title: "Song")
    #expect(try b.track("Renamed/x.flac")?.playCount == 1)
    #expect(try b.index.existingPathID(b.path("Album/x.flac")) == nil)
}

@Test func aMoveAfterTheNewPathWasPlayedMergesTheStats() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let old = try a.scanned("x.flac", title: "Song")
    let rated = try a.index.track(path: a.path("x.flac"))!.id
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.index.setRating(4, trackIDs: [rated])
    try a.index.toggle(.liked, trackIDs: [rated])
    let playlist = try a.index.createPlaylist(named: "Mix")
    _ = try a.index.addToPlaylist(playlist, trackIDs: [rated])
    try a.index.remove([old])
    try a.scanned("renamed.flac", title: "Song")
    #expect(try a.index.matchMoves().count == 1)
    // B scanned after the move, so it only has the new path, and played it.
    try b.scanned("renamed.flac", title: "Song")
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

/// A play count set by hand reaches the other Mac as the plays it adds over those counted, so
/// plays made after it, here or there, add to it, and the later of two sets wins without the
/// two adding up (ADR 0162).
@Test func aHandSetPlayCountSyncsAndPlaysAddToIt() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let onA = try a.scanned("x.flac")
    let onB = try b.scanned("x.flac")
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_100)
    try syncAll([a, b])
    #expect(try b.track("x.flac")?.playCount == 2)

    try a.index.setPlayCount(40, trackIDs: [onA])
    #expect(try a.track("x.flac")?.playCount == 40)
    #expect(try a.history("x.flac") == 2, "the plays logged stay")
    try syncAll([a, b])
    #expect(try b.track("x.flac")?.playCount == 40)

    try b.index.recordPlay(b.path("x.flac"), at: 1_700_000_200)
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_300)
    try syncAll([a, b])
    #expect(try a.track("x.flac")?.playCount == 42)
    #expect(try b.track("x.flac")?.playCount == 42)

    // Both set it, B later: B's stands everywhere, not the two added.
    try a.index.setPlayCount(10, trackIDs: [onA])
    b.nowMs += 60_000
    try b.index.setPlayCount(5, trackIDs: [onB])
    try syncAll([a, b])
    #expect(try a.track("x.flac")?.playCount == 5)
    #expect(try b.track("x.flac")?.playCount == 5)

    // Set back to the plays counted, nothing is left over.
    b.nowMs += 60_000
    try b.index.setPlayCount(4, trackIDs: [onB])
    try syncAll([a, b])
    #expect(try a.track("x.flac")?.playCount == 4)
    let offsets = try a.index.database.prepare("SELECT count(*) FROM \(playCountOffsetsTable)")
        .map { try $0.int(0) }[0]
    #expect(offsets == 0)
}

/// A count set below the plays a Mac has counted shows 0 there until the plays it was set
/// over arrive, never below.
@Test func aCountSetBelowThePlaysAMacHasYetToReadShowsNone() throws {
    let nas = try SimulatedNAS()
    let b = try machines(1, nas)[0]
    let id = try b.scanned("x.flac")
    // As B reads A's set of 1 over A's 3 plays, which A's log hasn't given it yet.
    try b.index.inTransaction { try b.index.setPlayCountOffset(-2, of: id) }
    #expect(try b.track("x.flac")?.playCount == 0)
    for at in 0..<3 { try b.index.recordPlay(b.path("x.flac"), at: 1_700_000_000 + Double(at)) }
    #expect(try b.track("x.flac")?.playCount == 1)
}

/// A move carries a hand-set count with the plays, onto a path played since.
/// A path set below its counted plays merges by a move with its whole offset, so the plays
/// counted stay its plays and the other path's added.
@Test func aMoveOfAPathSetBelowItsPlaysKeepsThePlaysCounted() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let old = try a.scanned("x.flac", title: "Song")
    for at in 0..<2 { try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000 + Double(at)) }
    try a.index.remove([old])
    try a.scanned("renamed.flac", title: "Song")
    #expect(try a.index.matchMoves().count == 1)
    // B played the new path 3 times and has a set of 1 over 6 plays, the rest yet to come.
    let new = try b.scanned("renamed.flac", title: "Song")
    for at in 0..<3 {
        try b.index.recordPlay(b.path("renamed.flac"), at: 1_700_000_100 + Double(at))
    }
    try b.index.inTransaction { try b.index.setPlayCountOffset(-5, of: new) }
    try a.sync()
    try b.sync()
    let id = try #require(try b.track("renamed.flac")).id
    let (count, offset) = try b.index.database.prepare(
        """
        SELECT p.play_count, o.plays FROM plays p
        JOIN \(playCountOffsetsTable) o ON o.path_id = p.path_id WHERE p.path_id = ?
        """
    ).map(id) { (try $0.int(0), try $0.int(1)) }[0]
    #expect(offset == -5)
    #expect(count - offset == 5, "A's 2 plays and B's 3")
}

/// Setting a never-played track's count to 0 changes nothing, so it gains no stats, which
/// would make it a lost path's or a move's.
@Test func settingANeverPlayedTrackToNoPlaysAddsNoStats() throws {
    let nas = try SimulatedNAS()
    let machine = try machines(1, nas)[0]
    let id = try machine.scanned("x.flac")
    try machine.index.setPlayCount(0, trackIDs: [id])
    let rows = try machine.index.database.prepare(
        "SELECT \(hasStats("?1")), (SELECT count(*) FROM plays WHERE path_id = ?1)"
    ).map(id) { (try $0.int(0), try $0.int(1)) }[0]
    #expect(rows == (0, 0))
}

@Test func aMoveCarriesAHandSetCount() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let old = try a.scanned("x.flac", title: "Song")
    try a.index.setPlayCount(30, trackIDs: [old])
    try a.index.remove([old])
    try a.scanned("renamed.flac", title: "Song")
    #expect(try a.index.matchMoves().count == 1)
    #expect(try a.track("renamed.flac")?.playCount == 30)
    try b.scanned("renamed.flac", title: "Song")
    try b.index.recordPlay(b.path("renamed.flac"), at: 1_700_000_500)
    try syncAll([a, b])
    #expect(try b.track("renamed.flac")?.playCount == 31)
    #expect(try a.track("renamed.flac")?.playCount == 31)
}

/// Rebuilding the imports keeps a hand-set count; rebuilding the play counts part takes its
/// offsets out of the counts with it, leaving the plays counted.
/// Get Info sets a count by path; a path with no track in the index is left out.
@Test func theReaderSetsACountByPath() async throws {
    let nas = try SimulatedNAS()
    let machine = try machines(1, nas)[0]
    try machine.scanned("x.flac")
    let reader = try LibraryReader(databaseURL: machine.databaseURL)
    try await reader.setPlayCount(3, paths: [machine.path("x.flac"), machine.path("gone.flac")])
    #expect(try machine.track("x.flac")?.playCount == 3)
    #expect(try machine.index.existingPathID(machine.path("gone.flac")) == nil)
}

/// Get Info's stars rate by path; a path with no track in the index is left out.
@Test func theReaderSetsARatingByPath() async throws {
    let nas = try SimulatedNAS()
    let machine = try machines(1, nas)[0]
    try machine.scanned("x.flac")
    let reader = try LibraryReader(databaseURL: machine.databaseURL)
    try await reader.setRating(4, paths: [machine.path("x.flac"), machine.path("gone.flac")])
    #expect(try machine.track("x.flac")?.rating == 4)
    #expect(try machine.index.existingPathID(machine.path("gone.flac")) == nil)
}

@Test func aRebuildKeepsOrTakesOutTheOffsets() throws {
    let nas = try SimulatedNAS()
    var machine = try machines(1, nas)[0]
    let id = try machine.scanned("x.flac")
    try machine.index.recordPlay(machine.path("x.flac"), at: 1_700_000_000)
    try machine.index.setPlayCount(9, trackIDs: [id])
    for (part, count) in [(SchemaPart.imports, 9), (.playCounts, 1)] {
        try machine.index.database.execute(
            "UPDATE schema_identity SET sql = 'earlier' WHERE part = '\(part.rawValue)'")
        machine = try machine.reopened()
        #expect(try machine.track("x.flac")?.playCount == count, "\(part)")
    }
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

@Test func aLogSomeoneElseWroteIsntWrittenButTheOthersAreReadAndItCanStartAgain() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try a.scanned("x.flac")
    try b.scanned("x.flac")
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.sync()
    let log = URL(fileURLWithPath: nas.log(try a.id))
    try Data("{}\n".utf8).write(to: log)
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_100)
    try b.index.recordPlay(b.path("x.flac"), at: 1_700_000_200)
    try b.sync()
    let report = try a.sync()
    #expect(report.problems.contains { $0.contains("isn't what this Mac logged") })
    #expect(try Data(contentsOf: log) == Data("{}\n".utf8))
    // B's play still arrived.
    #expect(try a.track("x.flac")?.playCount == 3)
    // Moved away, the log is written again whole, and B counts nothing twice.
    try FileManager.default.removeItem(at: log)
    #expect(try a.sync().pushed == 3)
    let again = try b.sync()
    #expect(again.problems.allSatisfy { $0.contains("read again from the start") }, "\(again)")
    #expect(try b.track("x.flac")?.playCount == 3)
}

@Test func asecondCopyOfTheAppDoesntPushAtTheSameTime() throws {
    let nas = try SimulatedNAS()
    let a = try machines(1, nas)[0]
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    let lock = open(a.databaseURL.path + ".sync-lock", O_CREAT | O_RDWR, 0o644)
    defer { close(lock) }
    #expect(flock(lock, LOCK_EX) == 0)
    let report = try a.sync()
    #expect(report.pushed == 0)
    #expect(report.problems.contains { $0.contains("another copy of the app") })
    flock(lock, LOCK_UN)
    #expect(try a.sync().pushed == 1)
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
    // Importing the same library on B, or on A after its stats were rebuilt from the logs,
    // adds nothing.
    _ = try b.index.applyImport(library, prefix: PathPrefix(from: a.mount, to: b.mount))
    #expect(try b.track("x.flac")?.playCount == 7)
    try a.index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'stats'")
    let rebuilt = try LibraryIndex(at: a.databaseURL)
    _ = try rebuilt.locate(
        [WatchedFolder(path: folderInShare, share: share, kind: .network)],
        among: [MountedShare(url: share, mountPoint: a.mount)])
    _ = try rebuilt.sync(folder: folderName, at: nas.syncFolder)
    try rebuilt.store([Crafted(path: a.path("x.flac"), title: "x.flac").scanned])
    _ = try rebuilt.applyImport(library, prefix: nil)
    #expect(try rebuilt.track(path: a.path("x.flac"))?.playCount == 7)
}

extension Machine {
    /// Imports a Swinsian library that counts `plays` plays and `skips` skips of `name`.
    func importSwinsian(_ name: String, plays: Int, skips: Int = 0) throws {
        var library = PlayerLibrary(player: .swinsian, source: "/tmp/swinsian.sqlite")
        var track = PlayerTrack(path: path(name))
        track.plays = plays
        track.skips = skips
        library.tracks = [track]
        _ = try index.applyImport(library, prefix: nil)
    }

    func counts(_ name: String) throws -> [Int] {
        let track = try #require(try track(name))
        return [track.playCount, track.skipCount]
    }
}

@Test(arguments: [
    // Both import before either syncs, A first or B first.
    ["a", "b", "sync"], ["b", "a", "sync"],
    // One imports and syncs, then the other imports what it has already read.
    ["a", "sync", "b", "sync"], ["b", "sync", "a", "sync"],
    // Each syncs between the imports.
    ["sync", "a", "sync", "b", "sync"],
])
func theSameLibraryImportedOnTwoMachinesCountsOnce(_ steps: [String]) throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try a.scanned("x.flac")
    try b.scanned("x.flac")
    // A play recorded on each Mac is counted on both, whatever the imports do.
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try b.index.recordPlay(b.path("x.flac"), at: 1_700_000_100)
    for step in steps {
        switch step {
        case "a": try a.importSwinsian("x.flac", plays: 7, skips: 2)
        case "b": try b.importSwinsian("x.flac", plays: 7, skips: 2)
        default: try syncAll([a, b])
        }
    }
    #expect(try a.counts("x.flac") == [9, 2])
    #expect(try b.counts("x.flac") == [9, 2])
    #expect(try a.history("x.flac") == 2)
    #expect(try b.history("x.flac") == 2)
}

@Test func afterBothMachinesRebuildTheirImportCountsOneImportRestoresThemOnBoth() throws {
    let nas = try SimulatedNAS()
    var (a, b) = try machines(2, nas).pair
    try a.scanned("x.flac")
    try b.scanned("x.flac")
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    try a.importSwinsian("x.flac", plays: 7)
    try b.importSwinsian("x.flac", plays: 7)
    try syncAll([a, b])
    for machine in [a, b] {
        try machine.index.database.execute(
            "UPDATE schema_identity SET sql = 'older' WHERE part = 'imports'")
    }
    (a, b) = (try a.reopened(), try b.reopened())
    #expect(try a.counts("x.flac") == [1, 0])
    #expect(try b.counts("x.flac") == [1, 0])
    try b.importSwinsian("x.flac", plays: 8)
    try syncAll([a, b])
    #expect(try a.counts("x.flac") == [9, 0])
    #expect(try b.counts("x.flac") == [9, 0])
}

@Test func anImportAfterTheSourceGainedPlaysAddsOnlyTheGainOnEveryMachine() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    try a.scanned("x.flac")
    try b.scanned("x.flac")
    try a.importSwinsian("x.flac", plays: 7)
    try b.importSwinsian("x.flac", plays: 7)
    try syncAll([a, b])
    try b.index.recordPlay(b.path("x.flac"), at: 1_700_000_000)
    // The source gained 3 plays, and B imports it.
    try b.importSwinsian("x.flac", plays: 10)
    #expect(try b.counts("x.flac") == [11, 0])
    try syncAll([a, b])
    #expect(try a.counts("x.flac") == [11, 0])
    // An older copy of the source, on either Mac, adds nothing and takes nothing away.
    try a.importSwinsian("x.flac", plays: 8)
    try syncAll([a, b])
    #expect(try a.counts("x.flac") == [11, 0])
    #expect(try b.counts("x.flac") == [11, 0])
}

@Test func anImportsLastPlayReachesTheOtherMachinesThoughItsPlayedLaterHere() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let id = try a.scanned("x.flac")
    try b.scanned("x.flac")
    try a.index.recordPlay(a.path("x.flac"), at: 1_700_000_000)
    var library = PlayerLibrary(player: .swinsian, source: "/tmp/swinsian.sqlite")
    var track = PlayerTrack(path: a.path("x.flac"))
    track.plays = 3
    track.lastPlayedSeconds = 1_600_000_000
    library.tracks = [track]
    _ = try a.index.applyImport(library, prefix: nil)
    try syncAll([a, b])
    let lastPlays = { (machine: Machine) in
        try machine.index.database.prepare(
            "SELECT path_id, played_at FROM \(importedLastPlaysTable) WHERE player = 'swinsian'"
        ).map { [try $0.int64(0): try $0.int64(1)] }
    }
    #expect(try lastPlays(a) == [[id: 1_600_000_000]])
    let other = try #require(try b.track("x.flac")).id
    #expect(try lastPlays(b) == [[other: 1_600_000_000]])
    #expect(try b.track("x.flac")?.playCount == 4)
    #expect(try b.track("x.flac")?.lastPlayedSeconds == 1_700_000_000)
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

@Test func aScanBatchLogsOneLineAFolderAndEachFileGetsItsDateAdded() throws {
    let nas = try SimulatedNAS()
    let (a, b) = try machines(2, nas).pair
    let names = ["A/1.flac", "A/2.flac", "B/1.flac", "A/3.flac"]
    try a.index.store(names.map { Crafted(path: a.path($0), title: $0).scanned })
    let lines = try a.index.database.prepare("SELECT line FROM sync_outbox ORDER BY seq").map {
        try $0.text(0)
    }
    let events = try lines.map { try SyncRecord(line: Array($0.utf8)[...]).event }
    let added = try #require(try a.track("A/1.flac")).addedSeconds
    #expect(
        events == [
            .addedFiles(
                folder: "music/library/A", names: ["1.flac", "2.flac", "3.flac"], at: added),
            .addedFiles(folder: "music/library/B", names: ["1.flac"], at: added),
        ])
    Thread.sleep(forTimeInterval: 0.01)
    try b.index.store(names.map { Crafted(path: b.path($0), title: $0).scanned })
    try syncAll([a, b])
    for name in names { #expect(try b.track(name)?.addedSeconds == added) }
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
    #expect(
        report.problems == [
            "events for files outside this Mac's share folders, which it doesn't keep: 1"
        ])
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
