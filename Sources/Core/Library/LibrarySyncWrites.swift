import Foundation
import Log
import SQLite

private let logger = moduleLogger()

let pathSQL = "SELECT path FROM paths WHERE id = ?"
/// Moves noted at most, and how many of them one path's chain follows.
let maximumMoves = 100_000
let maximumMoveChain = 16
let syncPlaylistIDSQL = "SELECT id FROM \(syncPlaylistsTable) WHERE playlist_id = ?"
/// The playlist a sync ID names; NULL for one deleted.
let syncPlaylistSQL = "SELECT playlist_id FROM \(syncPlaylistsTable) WHERE id = ?"
/// A playlist's sync ID; a NULL playlist marks one deleted.
let insertSyncPlaylistSQL = "INSERT INTO \(syncPlaylistsTable) (id, playlist_id) VALUES (?, ?)"

/// A field whose latest change wins (ADR 0038): a path's rating, opinion (`loved`, which
/// `disliked` events share) or hand-set play count (ADR 0162), keyed by path ID, a
/// playlist's name, rules or entries, keyed by playlist ID, or a release's Never Upgrade mark
/// (ADR 0200), keyed by its Discogs release id.
enum SyncField: String {
    case rating, loved, playlistName, playlistRules, playlistEntries, playCount, neverUpgrade
}

/// A scan batch's new sync paths, which the log takes as one `addedFiles` event a folder, in
/// the order the folders came, at most `maximumAddedNames` names each (ADR 0098).
struct SyncAdded {
    /// When the batch saw them: their Date Added.
    let at: Double
    private var folders: [String] = []
    private var names: [String: [String]] = [:]
    /// Sync paths with no folder, which can't be grouped.
    private var loose: [String] = []

    init(at: Double) { self.at = at }

    mutating func add(_ syncPath: String) {
        guard let slash = syncPath.lastIndex(of: "/") else { return loose.append(syncPath) }
        let folder = String(syncPath[..<slash])
        if names[folder] == nil { folders.append(folder) }
        names[folder, default: []].append(String(syncPath[syncPath.index(after: slash)...]))
    }

    var events: [SyncEvent] {
        let cap = SyncRecord.maximumAddedNames
        return folders.flatMap { folder in
            let all = names[folder] ?? []
            return stride(from: 0, to: all.count, by: cap).map {
                SyncEvent.addedFiles(
                    folder: folder, names: Array(all[$0..<min($0 + cap, all.count)]), at: at)
            }
        } + loose.map { .added(path: $0, at: at) }
    }
}

/// This machine's log (ADR 0038): each change appends its event in the transaction that makes
/// it, so the event is stored exactly when the change is, by any connection.
extension LibraryIndex {
    /// The ID this machine's log is named by in the sync folder.
    package func machineID() throws -> String {
        try statement("SELECT machine FROM \(syncStateTable)").map { try $0.text(0) }[0]
    }

    /// Runs `body` in a transaction, or in the caller's when there is one.
    func inTransaction<T>(_ body: () throws -> T) throws -> T {
        database.isInTransaction ? try body() : try database.transaction(body)
    }

    /// Where this machine has each share folder, as `share_roots` says now.
    func syncRoots() throws -> SyncRoots {
        SyncRoots(
            try statement("SELECT share, inner_path, root FROM \(shareRootsTable)").map {
                (try $0.text(0), try $0.text(1), try $0.text(2))
            })
    }

    /// The sync path of the path `id`; nil for one outside every share folder.
    func syncPath(ofPathID id: Int64, _ roots: SyncRoots) throws -> String? {
        try statement(pathSQL).map(id) { try $0.text(0) }.first.flatMap(roots.syncPath)
    }

    /// The change `field` of `key` holds; nil for none since this build, which any event beats.
    func stamp(_ field: SyncField, _ key: Int64) throws -> SyncStamp? {
        try statement("SELECT ms, n, machine FROM \(syncItemsTable) WHERE item = ? AND key = ?")
            .map(field.rawValue, key) {
                SyncStamp(
                    clock: SyncClock(ms: try $0.int64(0), counter: try $0.int64(1)),
                    machine: try $0.text(2))
            }.first
    }

    func deleteStamp(_ field: SyncField, _ key: Int64) throws {
        try statement("DELETE FROM \(syncItemsTable) WHERE item = ? AND key = ?").run(
            field.rawValue, key)
    }

    func setStamp(_ field: SyncField, _ key: Int64, _ stamp: SyncStamp) throws {
        try statement(
            "INSERT OR REPLACE INTO \(syncItemsTable) (item, key, ms, n, machine) VALUES (?, ?, ?, ?, ?)"
        ).run(field.rawValue, key, stamp.clock.ms, stamp.clock.counter, stamp.machine)
    }

    /// Appends `event` to this machine's log, in the caller's transaction, and returns when it
    /// was made. An edit of `field` comes after the change the field holds, and becomes it.
    /// Nil when it wasn't logged: the log is at a cap, or the line is too long, each said once
    /// in the window's notices.
    @discardableResult
    func logSync(_ event: SyncEvent, field: (SyncField, Int64)? = nil) throws -> SyncStamp? {
        precondition(database.isInTransaction, "a sync event outside a transaction: \(event)")
        let state = try statement(
            "SELECT machine, clock_ms, clock_n, log_bytes, full, (SELECT ifnull(max(seq), 0) FROM"
                + " \(syncOutboxTable)) FROM \(syncStateTable)"
        ).map { row in
            (
                machine: try row.text(0),
                clock: SyncClock(ms: try row.int64(1), counter: try row.int64(2)),
                bytes: try row.int(3), full: try row.int(4) == 1, seq: try row.int64(5)
            )
        }[0]
        guard !state.full else { return nil }
        let held = try field.flatMap { try stamp($0.0, $0.1) }
        let (clock, next) = SyncClock.next(
            after: state.clock, wallMs: wallClockMs(), field: held?.clock)
        let line = SyncRecord(seq: state.seq + 1, clock: clock, event: event).line
        let bytes = line.utf8.count + 1
        guard bytes <= SyncRecord.maximumLineBytes else {
            let detail =
                "a \(event.name) change wasn't shared with the other Macs: its line is \(bytes)"
                + " bytes, over the sync log's \(SyncRecord.maximumLineBytes)"
            logger.error("\(detail)")
            try recordDiscard(detail)
            return nil
        }
        guard state.seq < SyncRecord.maximumEvents,
            state.bytes + bytes <= SyncRecord.maximumLogBytes
        else {
            let detail =
                "this Mac's sync log is full (\(state.seq) events, \(state.bytes) bytes), so"
                + " its changes from now on stay on this Mac"
            logger.error("\(detail)")
            try statement("UPDATE \(syncStateTable) SET full = 1").run()
            try recordDiscard(detail)
            return nil
        }
        try statement("INSERT INTO \(syncOutboxTable) (seq, line) VALUES (?, ?)").run(
            state.seq + 1, line)
        try statement(
            "UPDATE \(syncStateTable) SET clock_ms = ?, clock_n = ?, log_bytes = log_bytes + ?"
        ).run(next.ms, next.counter, bytes)
        let made = SyncStamp(clock: clock, machine: state.machine)
        if let field { try setStamp(field.0, field.1, made) }
        return made
    }

    /// Logs `event(syncPath)` for the path `id`, when it's in a share folder.
    func logSync(
        pathID id: Int64, _ roots: SyncRoots, field: SyncField? = nil,
        _ event: (String) -> SyncEvent
    ) throws {
        guard let path = try syncPath(ofPathID: id, roots) else { return }
        try logSync(event(path), field: field.map { ($0, id) })
    }

    // MARK: Moves

    /// Notes that `from` moved to `to`, both sync paths, so an event for `from` read later
    /// goes to `to`. A move back forgets the first. Past `maximumMoves` nothing more is noted.
    func recordMove(from: String, to: String) throws {
        try statement("DELETE FROM \(syncMovesTable) WHERE from_path = ?").run(to)
        let count = try statement("SELECT count(*) AS moves FROM \(syncMovesTable)").map {
            try $0.int(0)
        }[0]
        guard count < maximumMoves else {
            logger.error("\(count) moves are noted, the most kept; \(from) to \(to) isn't")
            return
        }
        try statement(
            "INSERT OR REPLACE INTO \(syncMovesTable) (from_path, to_path) VALUES (?, ?)"
        ).run(from, to)
    }

    /// Where the sync path `path` is now, after the moves noted; a chain is followed a few
    /// steps at most, so a loop a log made can't hold a sync.
    func resolvedSyncPath(_ path: String) throws -> String {
        var current = path
        let next = try statement("SELECT to_path FROM \(syncMovesTable) WHERE from_path = ?")
        for _ in 0..<maximumMoveChain {
            guard let to = try next.map(current, row: { try $0.text(0) }).first, to != path
            else { break }
            current = to
        }
        return current
    }

    /// Whether the move of `from` to `to`, `paths` rows, is noted, as one this machine made in
    /// a share folder is; false for paths outside every share folder.
    func isNotedMove(from: String, to: String, _ roots: SyncRoots) throws -> Bool {
        guard let old = roots.syncPath(from), let new = roots.syncPath(to) else { return false }
        return try !statement(
            "SELECT 1 FROM \(syncMovesTable) WHERE from_path = ? AND to_path = ?"
        ).map(old, new, row: { _ in () }).isEmpty
    }

    // MARK: Playlists

    /// Forgets the changes the playlist `id`'s fields held, once it's deleted.
    func deleteStamps(ofPlaylist id: Int64) throws {
        for field in [SyncField.playlistName, .playlistRules, .playlistEntries] {
            try deleteStamp(field, id)
        }
    }

    /// The sync ID of the playlist `id`, and whether it was made now: a playlist made before
    /// this build gets one at its next change, and its create, and its entries when it has
    /// some, go in the log first.
    func syncPlaylistID(_ id: Int64) throws -> (id: String, adopted: Bool) {
        if let known = try statement(syncPlaylistIDSQL).map(id, row: { try $0.text(0) }).first {
            return (known, false)
        }
        let (name, rules) = try statement("SELECT name, rules FROM playlists WHERE id = ?").map(id)
        {
            (try $0.text(0), $0.optionalText(1))
        }[0]
        let syncID = try logCreate(id, name: name, rules: rules)
        if rules == nil, !(try playlistTrackIDs(id).isEmpty) { try logEntries(id, syncID) }
        return (syncID, true)
    }

    /// Gives the new playlist `id` a sync ID and logs its create.
    func logCreate(_ id: Int64, name: String, rules: String?) throws -> String {
        let syncID = newSyncID()
        try statement(insertSyncPlaylistSQL).run(syncID, id)
        // Every field holds the create, so the first edit of any of them comes after it.
        if let made = try logSync(.playlistCreate(playlist: syncID, name: name, rules: rules)) {
            for field in [SyncField.playlistName, .playlistRules, .playlistEntries] {
                try setStamp(field, id, made)
            }
        }
        return syncID
    }

    /// Logs the manual playlist `id`'s whole list of entries in a share folder.
    func logEntries(_ id: Int64) throws {
        let (syncID, adopted) = try syncPlaylistID(id)
        // Adopting it logged the list as it is now.
        if !adopted { try logEntries(id, syncID) }
    }

    private func logEntries(_ id: Int64, _ syncID: String) throws {
        let roots = try syncRoots()
        let paths = try statement(
            """
            SELECT p.path FROM playlist_entries e JOIN paths p ON p.id = e.path_id
            WHERE e.playlist_id = ? ORDER BY e.position
            """
        ).map(id) { try $0.text(0) }.compactMap(roots.syncPath)
        guard paths.count <= SyncRecord.maximumEntries else {
            let detail =
                "a playlist of \(paths.count) tracks wasn't shared with the other Macs: a sync log"
                + " takes \(SyncRecord.maximumEntries) at most"
            logger.error("\(detail)")
            try recordDiscard(detail)
            return
        }
        try logSync(.playlistEntries(playlist: syncID, paths: paths), field: (.playlistEntries, id))
    }
}
