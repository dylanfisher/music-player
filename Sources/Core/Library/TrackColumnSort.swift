import Settings

extension TrackColumn {
    /// What `LibraryIndex`'s track query orders by first. Its tables are `t` (tracks), `f`
    /// (files), `ar` (artist), `aa` (album artist), `al` (album), `g` (genre), `p` (plays), `r`
    /// (ratings) and, for playlist order, `pe` (the shown playlist's entries).
    var expression: String {
        switch self {
        case .title: "t.sort_title"
        case .artist: "ar.sort_name"
        case .album: "al.sort_title"
        case .albumArtist: "aa.sort_name"
        case .trackNumber: "t.track_number"
        case .discNumber: "t.disc_number"
        case .genre: "g.sort_name"
        // Null unless the date starts with four digits, so an untagged track has no year.
        case .year:
            "CASE WHEN substr(t.date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]'"
                + " THEN CAST(substr(t.date, 1, 4) AS INTEGER) END"
        case .duration: "CAST(t.length_frames AS REAL) / t.sample_rate_hz"
        case .codec: "t.codec"
        case .sampleRate: "t.sample_rate_hz"
        case .bitDepth: "t.bits_per_sample"
        case .dateAdded: "f.added_seconds"
        case .path: "f.path"
        case .playCount: "ifnull(p.play_count, 0)"
        case .skipCount: "ifnull(p.skip_count, 0)"
        case .lastPlayed: "p.last_played_seconds"
        case .rating: "ifnull(r.rating, 0)"
        case .playlistOrder: "pe.position"
        }
    }
}
