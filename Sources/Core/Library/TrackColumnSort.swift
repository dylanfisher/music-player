import Settings

extension TrackColumn {
    /// What `LibraryIndex`'s track query orders by first. Its tables are `t` (tracks), `f`
    /// (files), `ar` (artist), `aa` (album artist), `al` (album) and `g` (genre).
    var expression: String {
        switch self {
        case .title: "t.sort_title"
        case .artist: "ar.sort_name"
        case .album: "al.sort_title"
        case .albumArtist: "aa.sort_name"
        case .trackNumber: "t.track_number"
        case .discNumber: "t.disc_number"
        case .genre: "g.sort_name"
        case .year: "CAST(substr(t.date, 1, 4) AS INTEGER)"
        case .duration: "CAST(t.length_frames AS REAL) / t.sample_rate_hz"
        case .codec: "t.codec"
        case .sampleRate: "t.sample_rate_hz"
        case .bitDepth: "t.bits_per_sample"
        case .dateAdded: "f.added_seconds"
        case .path: "f.path"
        }
    }
}
