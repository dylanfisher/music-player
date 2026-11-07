/// The ways a release's tracklist can be an album's files (ADR 0131).
enum ReleaseTracklist {
    /// Headings are dropped, as no file holds one, unless no row has a position: then the dump
    /// had nothing to tell a track from a heading by, and every row is a track. An index
    /// track is its sub-tracks, one file per part; when the release has one, the list with
    /// each index track as a single file is a second way.
    static func flattenings(_ rows: [CatalogTrack]) -> [[CatalogTrack]] {
        let positioned = rows.contains { row in
            row.position != nil || row.subTracks.contains { $0.position != nil }
        }
        var parts: [CatalogTrack] = []
        var wholes: [CatalogTrack] = []
        for row in rows {
            switch row.kind {
            case .heading:
                guard !positioned else { continue }
                parts.append(row)
                wholes.append(row)
            case .track:
                parts.append(row)
                wholes.append(row)
            case .index:
                parts += row.subTracks.filter { !positioned || $0.kind != .heading }
                wholes.append(row)
            }
        }
        return parts == wholes ? [parts] : [parts, wholes]
    }

    /// A row's length: its own, or for an index track without one, its sub-tracks' together
    /// when each has one.
    static func seconds(_ track: CatalogTrack) -> Int? {
        if let seconds = track.durationSeconds { return seconds }
        guard track.kind == .index, !track.subTracks.isEmpty else { return nil }
        var total = 0
        for part in track.subTracks {
            guard let seconds = part.durationSeconds else { return nil }
            total += seconds
        }
        return total
    }
}
