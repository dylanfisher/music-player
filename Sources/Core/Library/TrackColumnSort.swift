import Settings

extension TrackColumn {
    /// What `LibraryIndex`'s track query orders by first. Its tables are `t` (tracks), `f`
    /// (files), `pa` (paths), `ar` (artist), `aa` (album artist), `ga` (the Artist pane's album
    /// artist), `al` (album), `g` (genre), `p` (plays), `r` (ratings), `lv` (loved) and, for
    /// playlist order, `pe` (the shown playlist's entries). Text the tags hold as written sorts
    /// without regard to ASCII case.
    var expression: String {
        switch self {
        case .rowNumber: preconditionFailure("the row number can't be sorted by")
        case .nowPlaying: preconditionFailure("Now Playing can't be sorted by")
        case .art: "t.art_offset IS NOT NULL"
        case .title: "t.sort_title"
        case .artist: "ar.sort_name"
        case .album: "al.sort_title"
        case .albumArtist: "aa.sort_name"
        case .composer: "t.composer COLLATE NOCASE"
        case .conductor: "t.conductor COLLATE NOCASE"
        case .lyricist: "t.lyricist COLLATE NOCASE"
        case .grouping: "t.grouping COLLATE NOCASE"
        case .work: "t.work COLLATE NOCASE"
        case .movementNumber: "t.movement_number"
        case .movementName: "t.movement_name COLLATE NOCASE"
        case .genre: "g.sort_name"
        // Null unless the date starts with four digits, so an untagged track has no year.
        case .year:
            "CASE WHEN substr(t.date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]'"
                + " THEN CAST(substr(t.date, 1, 4) AS INTEGER) END"
        case .originalDate: "t.original_date"
        // "3 of 12" sorts as the number alone.
        case .trackNumber, .trackOfTotal: "t.track_number"
        case .trackTotal: "t.track_total"
        case .discNumber, .discOfTotal: "t.disc_number"
        case .discTotal: "t.disc_total"
        case .discSubtitle: "t.disc_subtitle COLLATE NOCASE"
        case .compilation: "t.compilation"
        case .duration: "CAST(t.length_frames AS REAL) / t.sample_rate_hz"
        case .bpm: "t.bpm"
        case .key: "t.musical_key COLLATE NOCASE"
        case .codec: "t.codec"
        case .fileType: fileTypeSQL
        case .bitRate: bitRateSQL
        case .sampleRate: "t.sample_rate_hz"
        case .bitDepth: "t.bits_per_sample"
        case .channels: "t.channels"
        case .size: "f.size_bytes"
        case .fileName: fileNameSQL + nocase
        case .path: "f.path"
        case .dateAdded: "pa.added_seconds"
        case .dateCreated: "f.created_seconds"
        case .dateModified: "f.modified_seconds"
        case .playCount: "ifnull(p.play_count, 0)"
        case .skipCount: "ifnull(p.skip_count, 0)"
        case .lastPlayed: "p.last_played_seconds"
        case .rating: "ifnull(r.rating, 0)"
        case .loved: lovedSQL
        case .publisher: "t.publisher COLLATE NOCASE"
        case .catalogNumber: "t.catalog_number COLLATE NOCASE"
        case .barcode: "t.barcode"
        case .copyright: "t.copyright COLLATE NOCASE"
        case .encoder: "t.encoder COLLATE NOCASE"
        case .comment: "t.comment COLLATE NOCASE"
        case .description: "t.description COLLATE NOCASE"
        case .playlistOrder: "pe.position"
        }
    }
}

/// The file's name, from where `files.name_offset` says it starts in the path.
let fileNameSQL = "substr(f.path, f.name_offset)"

/// The file name's extension, uppercased: what follows its last dot.
let fileTypeSQL = """
    upper(substr(\(fileNameSQL), length(rtrim(\(fileNameSQL), replace(\(fileNameSQL), '.', ''))) + 1))
    """

/// The average bit rate in kilobits a second: the file's bytes without its art over its length.
/// Null for a track of no length. Tags and container overhead count.
let bitRateSQL =
    "(f.size_bytes - ifnull(t.art_byte_count, 0)) * 8.0 / (\(TrackColumn.duration.expression))"
    + " / 1000"

let lovedSQL = "lv.path_id IS NOT NULL"
