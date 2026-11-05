import Foundation
import SQLite

/// An event for a playlist whose create hasn't been read yet, from a log not read so far or a
/// clock that put the create later.
struct SyncWaitsForCreate: Error {
    var playlist: String
}

/// What a sync pass carries from one event to the next.
struct SyncMerge {
    let roots: SyncRoots
    /// Sync paths already mapped to `paths` rows this pass.
    var pathIDs: [String: Int64] = [:]
    /// Events for paths outside this machine's share folders, which it doesn't keep.
    var outside = 0
    /// `paths` rows the pass added.
    var newPaths = 0
    /// How many paths `pathIDs` holds before it's emptied, so a pass's memory stays bounded.
    static let maximumCachedPaths = 100_000
    /// Whether any event changed the library, so the window reads it again.
    var changed = false

    init(roots: SyncRoots) { self.roots = roots }
}

/// Applying other machines' events (ADR 0038). Nothing here logs an event of its own.
extension LibraryIndex {
    /// Applies `record` from the log of `machine`, inside the caller's transaction. Returns
    /// why it was skipped when that's a problem with the event; one outside this machine's
    /// folders is only counted.
    func apply(_ record: SyncRecord, from machine: String, _ merge: inout SyncMerge) throws
        -> String?
    {
        let stamp = SyncStamp(clock: record.clock, machine: machine)
        let seconds = Double(record.clock.ms) / 1000
        switch record.event {
        case .play(let path, let at):
            guard let id = try mergedPathID(path, seenAt: at, &merge) else { return nil }
            try addCounts(id, plays: 1, skips: 0, lastPlayed: at)
            try addHistory(id, at: at)
        case .skip(let path):
            guard let id = try mergedPathID(path, seenAt: seconds, &merge) else { return nil }
            try addCounts(id, plays: 0, skips: 1, lastPlayed: nil)
        case .counts(let path, let player, let plays, let skips, let lastPlayed):
            guard let id = try mergedPathID(path, seenAt: seconds, &merge) else { return nil }
            try addCounts(id, plays: plays, skips: skips, lastPlayed: lastPlayed)
            // So an import of the same library here, or after a rebuild, adds only what grew.
            try statement(
                """
                INSERT INTO \(importedPlaysTable) (player, path_id, play_count, skip_count)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (player, path_id) DO UPDATE SET
                    play_count = play_count + excluded.play_count,
                    skip_count = skip_count + excluded.skip_count
                """
            ).run(player.rawValue, id, plays, skips)
        case .rating(let path, let stars):
            guard let id = try mergedPathID(path, seenAt: seconds, &merge),
                try wins(stamp, .rating, id)
            else { return nil }
            try setRating(stars, of: id)
        case .loved(let path, let loved):
            guard let id = try mergedPathID(path, seenAt: seconds, &merge),
                try wins(stamp, .loved, id)
            else { return nil }
            try setOpinion(loved ? .liked : nil, of: id)
        case .disliked(let path):
            guard let id = try mergedPathID(path, seenAt: seconds, &merge),
                try wins(stamp, .loved, id)
            else { return nil }
            try setOpinion(.disliked, of: id)
        case .added(let path, let at):
            guard let id = try mergedPathID(path, seenAt: at, &merge) else { return nil }
            try statement(earliestAddedSQL).run(at, id)
        case .addedFiles(let folder, let names, let at):
            let earliest = try statement(earliestAddedSQL)
            for name in names {
                guard let id = try mergedPathID(folder + "/" + name, seenAt: at, &merge)
                else { continue }
                try earliest.run(at, id)
            }
        case .move(let from, let to):
            return try mergeMove(from: from, to: to, &merge)
        case .playlistCreate(let syncID, let name, let rules):
            guard case .unknown = try mergedPlaylist(syncID) else { return nil }
            let id = try insertPlaylist(named: name, rules: rules)
            try statement(insertSyncPlaylistSQL).run(syncID, id)
            for field in [SyncField.playlistName, .playlistRules, .playlistEntries] {
                try setStamp(field, id, stamp)
            }
        case .playlistRename(let syncID, let name):
            guard case .local(let id) = try mergedPlaylist(syncID) else {
                return try unknownPlaylist(syncID)
            }
            guard try wins(stamp, .playlistName, id) else { return nil }
            try statement(renamePlaylistSQL).run(name, id)
        case .playlistRules(let syncID, let rules):
            guard case .local(let id) = try mergedPlaylist(syncID) else {
                return try unknownPlaylist(syncID)
            }
            guard try isManual(id) == false else {
                return "it gives rules to a manual playlist"
            }
            guard try wins(stamp, .playlistRules, id) else { return nil }
            try statement(setRulesSQL).run(rules, id)
        case .playlistEntries(let syncID, let paths):
            guard case .local(let id) = try mergedPlaylist(syncID) else {
                return try unknownPlaylist(syncID)
            }
            guard try isManual(id) else { return "it gives entries to a smart playlist" }
            guard try wins(stamp, .playlistEntries, id) else { return nil }
            try statement("DELETE FROM playlist_entries WHERE playlist_id = ?").run(id)
            let insert = try statement(insertEntrySQL)
            var position = 0
            for path in paths {
                guard let track = try mergedPathID(path, seenAt: seconds, &merge) else { continue }
                try insert.run(id, track, position)
                position += database.changes
            }
        case .playlistDelete(let syncID):
            switch try mergedPlaylist(syncID) {
            case .deleted: return nil
            case .unknown:
                // Kept, so a create read later doesn't bring it back.
                try statement(
                    "INSERT INTO \(syncPlaylistsTable) (id, playlist_id) VALUES (?, NULL)"
                )
                .run(syncID)
            case .local(let id):
                try statement(deletePlaylistSQL).run(id)
                try deleteStamps(ofPlaylist: id)
            }
        }
        merge.changed = true
        return nil
    }

    /// The `paths` row of `syncPath`, added as first seen at `seconds` when this machine has
    /// none; nil, counted, for a path outside its share folders.
    private func mergedPathID(_ syncPath: String, seenAt seconds: Double, _ merge: inout SyncMerge)
        throws -> Int64?
    {
        if let id = merge.pathIDs[syncPath] { return id }
        guard let path = merge.roots.localPath(try resolvedSyncPath(syncPath)) else {
            merge.outside += 1
            return nil
        }
        let nfc = path.precomposedStringWithCanonicalMapping
        let id: Int64
        if let known = try existingPathID(nfc) {
            id = known
        } else {
            id = try pathID(nfc, seenAt: seconds)
            merge.newPaths += 1
        }
        if merge.pathIDs.count >= SyncMerge.maximumCachedPaths { merge.pathIDs = [:] }
        merge.pathIDs[syncPath] = id
        return id
    }

    private func addCounts(_ id: Int64, plays: Int, skips: Int, lastPlayed: Double?) throws {
        try statement(addPlaysSQL).run(id, plays, skips, lastPlayed)
    }

    private func setRating(_ stars: Int?, of id: Int64) throws {
        if let stars, stars > 0 {
            try statement(setRatingSQL).run(id, stars)
        } else {
            try statement(deleteRatingSQL).run(id)
        }
    }

    /// Whether `stamp` is later than the change `field` of `key` holds, recording it if so.
    private func wins(_ stamp: SyncStamp, _ field: SyncField, _ key: Int64) throws -> Bool {
        if let held = try self.stamp(field, key), held >= stamp { return false }
        try setStamp(field, key, stamp)
        return true
    }

    private enum MergedPlaylist {
        case unknown, deleted
        case local(Int64)
    }

    private func mergedPlaylist(_ syncID: String) throws -> MergedPlaylist {
        guard
            let row = try statement(syncPlaylistSQL).map(
                syncID, row: { $0.optionalInt(0).map(Int64.init) }
            ).first
        else { return .unknown }
        return row.map { .local($0) } ?? .deleted
    }

    /// Nothing, for an event for the playlist `syncID` deleted here; one for a playlist no log
    /// read so far created waits for its create, before anything is written.
    private func unknownPlaylist(_ syncID: String) throws -> String? {
        if case .deleted = try mergedPlaylist(syncID) { return nil }
        throw SyncWaitsForCreate(playlist: syncID)
    }

    private func isManual(_ id: Int64) throws -> Bool {
        try statement("SELECT rules IS NULL FROM playlists WHERE id = ?").map(id) {
            try $0.int(0) == 1
        }[0]
    }

    // MARK: Moves

    /// Another machine's scan matched `from` to `to` (ADR 0026). Without a row for `from`,
    /// this machine made the move itself or never had the path. With one and none for `to`,
    /// the row takes the new path. With both, the stats of `to` join `from`'s row, which then
    /// takes the new path, unless both have a file here.
    private func mergeMove(from: String, to movedTo: String, _ merge: inout SyncMerge) throws
        -> String?
    {
        // A move read before an earlier one of its new path goes on to where that one led.
        let to = try resolvedSyncPath(movedTo)
        guard let fromPath = merge.roots.localPath(from), let toPath = merge.roots.localPath(to)
        else {
            merge.outside += 1
            return nil
        }
        merge.pathIDs = [:]
        let oldNFC = fromPath.precomposedStringWithCanonicalMapping
        let newNFC = toPath.precomposedStringWithCanonicalMapping
        guard oldNFC != newNFC else { return "it moves \(clipped(from)) onto itself" }
        let old = try existingPathID(oldNFC)
        if let old,
            try !statement("SELECT 1 FROM files WHERE id = ?").map(old, row: { _ in () })
                .isEmpty
        {
            // The file is still here as far as this index knows; its own scan matches the move.
            return "this Mac still has \(clipped(from)), so the move to \(clipped(to)) waits for"
                + " its own scan"
        }
        try recordMove(from: from, to: to)
        guard let old else { return nil }
        if let new = try existingPathID(newNFC) {
            try absorb(new, into: old)
            try move(old, to: new)
        } else {
            try statement("UPDATE paths SET path = ? WHERE id = ?").run(newNFC, old)
        }
        merge.changed = true
        return nil
    }

    /// Moves the stats of the path `gone` onto `kept`, by the merge rules: counts added, the
    /// history moved, the later rating and opinion, the earliest Date Added. Leaves `gone` with no
    /// stats. Call inside a transaction.
    private func absorb(_ gone: Int64, into kept: Int64) throws {
        if let counts = try statement(
            "SELECT play_count, skip_count, last_played_seconds FROM plays WHERE path_id = ?"
        ).map(gone, row: { (try $0.int(0), try $0.int(1), $0.optionalDouble(2)) }).first {
            try addCounts(kept, plays: counts.0, skips: counts.1, lastPlayed: counts.2)
            try statement("DELETE FROM plays WHERE path_id = ?").run(gone)
        }
        try statement("UPDATE history SET path_id = ? WHERE path_id = ?").run(kept, gone)
        // Replacing `kept`'s own row, when it has one, leaves it marked once.
        try statement("UPDATE OR REPLACE \(recordedTable) SET path_id = ? WHERE path_id = ?").run(
            kept, gone)
        let rating = try statement("SELECT rating FROM ratings WHERE path_id = ?")
        let ratings: [Int?] = try [gone, kept].map { id in
            try rating.map(id, row: { try $0.int(0) }).first
        }
        if try takesGone(
            .rating, gone, kept, goneHas: ratings[0] != nil, keptHas: ratings[1] != nil)
        {
            try setRating(ratings[0], of: kept)
        }
        try statement(deleteRatingSQL).run(gone)
        let opinions = try [gone, kept].map(opinion(of:))
        if try takesGone(
            .loved, gone, kept, goneHas: opinions[0] != nil, keptHas: opinions[1] != nil)
        {
            try setOpinion(opinions[0], of: kept)
        }
        try setOpinion(nil, of: gone)
        try statement("UPDATE OR IGNORE playlist_entries SET path_id = ? WHERE path_id = ?").run(
            kept, gone)
        try statement("DELETE FROM playlist_entries WHERE path_id = ?").run(gone)
        try statement(
            """
            UPDATE paths SET added_seconds = min(added_seconds,
                (SELECT added_seconds FROM paths WHERE id = ?))
            WHERE id = ?
            """
        ).run(gone, kept)
        try statement("UPDATE OR IGNORE \(importedPlaysTable) SET path_id = ? WHERE path_id = ?")
            .run(kept, gone)
    }

    /// Whether `kept` takes `gone`'s value of `field`: the later change, or with no clock on
    /// either, `gone`'s when only it has a value. The winner's clock goes to `kept`.
    private func takesGone(
        _ field: SyncField, _ gone: Int64, _ kept: Int64, goneHas: Bool, keptHas: Bool
    ) throws -> Bool {
        let goneStamp = try stamp(field, gone)
        let keptStamp = try stamp(field, kept)
        let takes: Bool
        switch (goneStamp, keptStamp) {
        case (let goneStamp?, let keptStamp?): takes = goneStamp > keptStamp
        case (.some, nil): takes = true
        case (nil, .some): takes = false
        case (nil, nil): takes = goneHas && !keptHas
        }
        if takes, let goneStamp { try setStamp(field, kept, goneStamp) }
        try deleteStamp(field, gone)
        return takes
    }
}
