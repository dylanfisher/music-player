import Foundation
import Log
import SQLite

private let logger = moduleLogger()

let pathSQL = "SELECT path FROM paths WHERE id = ?"
let syncPlaylistIDSQL = "SELECT id FROM \(syncPlaylistsTable) WHERE playlist_id = ?"
/// A playlist's sync ID; a NULL playlist marks one deleted.
let insertSyncPlaylistSQL = "INSERT INTO \(syncPlaylistsTable) (id, playlist_id) VALUES (?, ?)"

/// A field whose latest change wins (ADR 0038): a path's rating or love, keyed by path ID, or a
/// playlist's name, rules or entries, keyed by playlist ID.
enum SyncField: String {
    case rating, loved, playlistName, playlistRules, playlistEntries
}

/// This machine's log (ADR 0038): each change appends its event in the transaction that makes
/// it, so the event is stored exactly when the change is, by any connection.
extension LibraryIndex {
    /// The ID this machine's log is named by in the sync folder.
    func machineID() throws -> String {
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
        if let made = try logSync(.playlistCreate(playlist: syncID, name: name, rules: rules)) {
            try setStamp(.playlistName, id, made)
            try setStamp(.playlistRules, id, made)
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
        ).map(id) { try $0.text(0) }
        try logSync(
            .playlistEntries(playlist: syncID, paths: paths.compactMap(roots.syncPath)),
            field: (.playlistEntries, id))
    }
}
