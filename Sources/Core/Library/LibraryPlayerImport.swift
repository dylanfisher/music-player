import Foundation
import SQLite

/// Importing another player's library (ADR 0033): matched by path, merged field by field, and
/// written in one transaction only when the owner confirms.
extension LibraryIndex {
    /// What importing `library` would change, read without writing.
    func importPlan(_ library: PlayerLibrary, prefix: PathPrefix?) throws -> ImportPlan {
        var plan = ImportPlan(library: library, prefix: prefix)
        plan.mergedRows = library.mergedRows
        let paths = library.tracks.map { prefix?.apply($0.path) ?? $0.path }
        let ids = try trackIDs(atPaths: paths)
        var trackByPath: [String: Int64] = [:]
        var merged: [Int64: PlayerTrack] = [:]
        var order: [Int64] = []
        for ((track, path), id) in zip(zip(library.tracks, paths), ids) {
            guard let id else {
                plan.unmatched.append(path)
                continue
            }
            trackByPath[track.path] = id
            if merged[id] == nil {
                merged[id] = track
                order.append(id)
            } else {
                merged[id]?.merge(track)
                plan.mergedRows += 1
            }
        }
        plan.matched = order.count
        let ours = Dictionary(
            uniqueKeysWithValues: try inChunks(order, { "\(oursSelect) WHERE pa.id IN (\($0))" }) {
                (try $0.int64(0), try OurStats($0))
            })
        let recorded = Dictionary(
            uniqueKeysWithValues: try statement(
                "SELECT path_id, play_count, skip_count FROM \(importedPlaysTable) WHERE player = ?"
            ).map(library.player.rawValue) {
                (try $0.int64(0), ImportedCounts(plays: try $0.int(1), skips: try $0.int(2)))
            })
        for id in order {
            guard let theirs = merged[id], let our = ours[id] else { continue }
            let before = recorded[id] ?? ImportedCounts(plays: 0, skips: 0)
            let now = ImportedCounts(plays: theirs.plays, skips: theirs.skips)
            var update = TrackUpdate(
                pathID: id, plays: max(0, now.plays - before.plays),
                skips: max(0, now.skips - before.skips),
                imported: now == before ? nil : now, loves: theirs.loved && !our.loved)
            if let played = theirs.lastPlayedSeconds, played > our.lastPlayedSeconds ?? -.infinity {
                update.lastPlayedSeconds = played
                plan.lastPlayed += 1
            }
            if let added = theirs.addedSeconds, added < our.addedSeconds {
                update.addedSeconds = added
                plan.dateAdded += 1
            }
            if let rating = theirs.rating {
                if our.rating == nil {
                    update.rating = rating
                    plan.ratings += 1
                    if theirs.ratingRounded { plan.roundedRatings += 1 }
                } else if our.rating != rating {
                    plan.ratingsKept += 1
                }
            }
            plan.playsAdded += update.plays
            plan.skipsAdded += update.skips
            if update.plays > 0 { plan.tracksGainingPlays += 1 }
            if update.skips > 0 { plan.tracksGainingSkips += 1 }
            if update.loves { plan.loved += 1 }
            if !update.writesNothing { plan.updates.append(update) }
        }
        var names = Set(try playlists().map { playlistKey($0.name) })
        for playlist in library.playlists {
            let kind: PlannedPlaylist.Kind
            var planned: PlannedPlaylist
            switch playlist.kind {
            case .unmapped: continue
            case .smart(let rules):
                kind = .smart(rules)
                planned = PlannedPlaylist(name: playlist.name, kind: kind)
            case .manual, .smartAsManual:
                var seen = Set<Int64>()
                var entries: [Int64] = []
                var missing = playlist.entriesWithoutFiles
                var repeated = 0
                for path in playlist.paths {
                    guard let id = trackByPath[path] else {
                        missing += 1
                        continue
                    }
                    if seen.insert(id).inserted { entries.append(id) } else { repeated += 1 }
                }
                planned = PlannedPlaylist(name: playlist.name, kind: .manual(entries))
                planned.wasSmart = playlist.kind == .smartAsManual
                planned.missing = missing
                planned.repeated = repeated
            }
            guard names.insert(playlistKey(playlist.name)).inserted else {
                plan.existingPlaylists.append(playlist.name)
                continue
            }
            plan.playlists.append(planned)
        }
        return plan
    }

    /// Recomputes the plan inside one transaction and writes it, so plays and scans since the
    /// preview are added to, not overwritten. Returns what was written.
    func applyImport(_ library: PlayerLibrary, prefix: PathPrefix?) throws -> ImportPlan {
        try database.transaction {
            let plan = try importPlan(library, prefix: prefix)
            let plays = try statement(addPlaysSQL)
            let recordCounts = try statement(
                "INSERT OR REPLACE INTO \(importedPlaysTable) (player, path_id, play_count,"
                    + " skip_count) VALUES (?, ?, ?, ?)")
            let added = try statement(earliestAddedSQL)
            let rate = try statement(
                "INSERT OR IGNORE INTO ratings (path_id, rating) VALUES (?, ?)")
            let love = try statement(insertLovedSQL)
            let roots = try syncRoots()
            // What the import changed reaches the other machines as events (ADR 0038).
            for update in plan.updates {
                let id = update.pathID
                if update.plays > 0 || update.skips > 0 || update.lastPlayedSeconds != nil {
                    try plays.run(id, update.plays, update.skips, update.lastPlayedSeconds)
                    try logSync(pathID: id, roots) {
                        .counts(
                            path: $0, plays: update.plays, skips: update.skips,
                            lastPlayed: update.lastPlayedSeconds)
                    }
                }
                if let counts = update.imported {
                    try recordCounts.run(library.player.rawValue, id, counts.plays, counts.skips)
                }
                if let seconds = update.addedSeconds {
                    try added.run(seconds, id)
                    try logSync(pathID: id, roots) { .added(path: $0, at: seconds) }
                }
                if let stars = update.rating {
                    try rate.run(id, stars)
                    try logSync(pathID: id, roots, field: .rating) {
                        .rating(path: $0, stars: stars)
                    }
                }
                if update.loves {
                    try love.run(id)
                    try logSync(pathID: id, roots, field: .loved) { .loved(path: $0, loved: true) }
                }
            }
            for playlist in plan.playlists {
                switch playlist.kind {
                case .manual(let ids):
                    _ = try appendEntries(try createPlaylist(named: playlist.name), ids)
                case .smart(let rules):
                    _ = try createPlaylist(named: playlist.name, rules: rules)
                }
            }
            return plan
        }
    }
}

/// Adds plays and skips to a path's counts, keeping the latest Last Played.
let addPlaysSQL = """
    INSERT INTO plays (path_id, play_count, skip_count, last_played_seconds)
    VALUES (?, ?, ?, ?)
    ON CONFLICT (path_id) DO UPDATE SET
        play_count = play_count + excluded.play_count,
        skip_count = skip_count + excluded.skip_count,
        last_played_seconds = max(
            ifnull(last_played_seconds, excluded.last_played_seconds),
            ifnull(excluded.last_played_seconds, last_played_seconds))
    """

/// Keeps the earlier of a path's Date Added and the one given.
let earliestAddedSQL = "UPDATE paths SET added_seconds = min(added_seconds, ?) WHERE id = ?"

/// A playlist's name as imports compare it: in NFC, ignoring case.
private func playlistKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
}

private let oursSelect = """
    SELECT pa.id, pa.added_seconds, p.last_played_seconds, r.rating, lv.path_id IS NOT NULL
    FROM paths pa
    LEFT JOIN plays p ON p.path_id = pa.id
    LEFT JOIN ratings r ON r.path_id = pa.id
    LEFT JOIN \(lovedTable) lv ON lv.path_id = pa.id
    """

/// What the library holds for a track before the import.
private struct OurStats {
    var addedSeconds: Double
    var lastPlayedSeconds: Double?
    var rating: Int?
    var loved: Bool

    init(_ row: Row) throws {
        addedSeconds = try row.double(1)
        lastPlayedSeconds = row.optionalDouble(2)
        rating = row.optionalInt(3)
        loved = try row.int(4) == 1
    }
}
