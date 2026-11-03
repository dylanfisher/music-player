import DisplayText
import Settings

/// How a browser column reads its entries from tracks `t` and the tables `trackJoins` joins.
enum GroupingSQL {
    /// Rows of a table whose IDs the tracks' `column` holds. `rows` selects each row's ID and
    /// name, or for albums `albumRows`'s columns; `order` sorts them.
    case table(rows: String, column: String, order: String, albums: Bool)
    /// A text each track has: `value`, sorted by `order`, ignoring case where `caseless`.
    case value(value: String, order: String, caseless: Bool)
}

/// An album's ID, title, artist and whether it's a compilation without an album artist.
let albumRows = """
    SELECT id, title, (SELECT name FROM artists WHERE id = albums.artist_id),
        albums.artist_id IS NULL AND EXISTS (SELECT 1 FROM tracks
            WHERE album_id = albums.id AND compilation = 1)
    FROM albums
    """

extension BrowserGrouping {
    func sql(_ filter: TrackFilter) -> GroupingSQL {
        let artists = "SELECT id, name FROM artists"
        switch self {
        case .genres:
            return .table(
                rows: "SELECT id, name FROM genres", column: "genre_id", order: "sort_name",
                albums: false)
        case .artists:
            return .table(
                rows: artists, column: artistColumn(filter), order: "sort_name", albums: false)
        case .albumArtists:
            return .table(
                rows: artists, column: "album_artist_id", order: "sort_name", albums: false)
        case .artistsAndAlbumArtists:
            return .table(
                rows: artists, column: "group_artist_id", order: "sort_name", albums: false)
        case .albums:
            return .table(rows: albumRows, column: "album_id", order: "sort_title", albums: true)
        case .albumsByYear:
            // An album's year is its earliest track's; albums with none come last.
            let year =
                "(SELECT min(\(TrackColumn.year.expression)) FROM tracks t"
                + " WHERE t.album_id = albums.id)"
            return .table(
                rows: albumRows, column: "album_id", order: "\(year) IS NULL, \(year), sort_title",
                albums: true)
        case .years:
            let year = TrackColumn.year.expression
            return .value(value: "CAST(\(year) AS TEXT)", order: year, caseless: false)
        case .composers: return .tag("t.composer")
        case .publishers: return .tag("t.publisher")
        case .groupings: return .tag("t.grouping")
        case .conductors: return .tag("t.conductor")
        case .comments: return .tag("t.comment")
        case .descriptions: return .tag("t.description")
        case .lyricists: return .tag("t.lyricist")
        case .works: return .tag("t.work")
        case .initialKeys: return .tag("t.musical_key")
        case .originalReleaseDates:
            let date = TrackColumn.originalDate.expression
            return .value(value: date, order: date, caseless: false)
        case .audioQuality:
            return .value(
                value:
                    "ifnull(t.bits_per_sample || '-bit ', '')"
                    + " || printf('%g', t.sample_rate_hz / 1000.0) || ' kHz'",
                order: "ifnull(t.bits_per_sample, 0) * 10000000 + t.sample_rate_hz",
                caseless: false)
        case .channels:
            let channels = TrackColumn.channels.expression
            return .value(
                value: "CAST(\(channels) AS TEXT)", order: channels, caseless: false)
        case .fileTypes:
            return .value(value: fileTypeSQL, order: fileTypeSQL, caseless: false)
        case .fileNames:
            return .value(value: fileNameSQL, order: fileNameSQL, caseless: true)
        case .folders:
            // The path up to the slash before the file's name.
            let folder = "substr(f.path, 1, f.name_offset - 2)"
            return .value(value: folder, order: folder, caseless: false)
        case .ratings:
            let rating = TrackColumn.rating.expression
            return .value(value: "CAST(\(rating) AS TEXT)", order: rating, caseless: false)
        }
    }

    /// The condition on tracks `t` that holds for the tracks of one entry, which it binds.
    func condition(_ filter: TrackFilter) -> String {
        switch sql(filter) {
        case .table(_, let column, _, _): "t.\(column) = ?"
        case .value(let value, _, let caseless): "(\(value))\(caseless ? nocase : "") = ?"
        }
    }

    /// What a column shows for a value of this grouping's text.
    func displayName(_ text: String) -> String {
        switch self {
        case .ratings: text == "0" ? "Unrated" : stars(Int(text) ?? 0)
        case .channels:
            switch text {
            case "1": "Mono"
            case "2": "Stereo"
            default: "\(text) Channels"
            }
        default: text
        }
    }
}

/// Compares text ignoring ASCII case, as the table sorts tags.
let nocase = " COLLATE NOCASE"

extension GroupingSQL {
    /// A tag's text, ignoring case.
    static func tag(_ column: String) -> GroupingSQL {
        .value(value: column, order: column, caseless: true)
    }

    /// The text that follows the value or order to compare it.
    var collation: String {
        guard case .value(_, _, true) = self else { return "" }
        return nocase
    }
}

/// The column of tracks the Artists column lists and its selection matches.
func artistColumn(_ filter: TrackFilter) -> String {
    filter.groupByAlbumArtist ? "group_artist_id" : "artist_id"
}
