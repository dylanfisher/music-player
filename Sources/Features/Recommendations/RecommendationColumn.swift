import DisplayText
import Foundation
import Library
import Recommender
import Settings

/// A column of the Recommendations window's table, and its text for a row. On the Artists
/// view, Artist, Albums and Score are the artist's and the rest its best album's. Download is
/// the state of the newest download job of the album's release, from Downloads. Format, In
/// Library and Mark are a discography's, which lists the library's and the marked albums too.
enum RecommendationColumn: String, CaseIterable {
    case rank, artist, albums, title, year, label, styles, format, inLibrary, mark, rating, have
    case want, download, why, score
    case forSale, lowestPrice

    var title: String {
        switch self {
        case .rank: "Rank"
        case .artist: TrackColumn.artist.title
        case .albums: "Albums"
        case .title: TrackColumn.title.title
        case .year: TrackColumn.year.title
        case .label: "Label"
        case .styles: "Styles"
        case .format: "Format"
        case .inLibrary: "In Library"
        case .mark: markColumnTitle
        case .rating: "Rating"
        case .have: "Have"
        case .want: "Want"
        case .download: "Download"
        case .why: "Why"
        case .score: "Score"
        case .forSale: "For Sale"
        case .lowestPrice: "Lowest Price"
        }
    }

    var width: Double {
        switch self {
        case .artist, .title: 180
        case .label, .styles, .download, .format: 140
        case .mark: 100
        case .inLibrary: 70
        case .why: 320
        case .rating: 80
        case .rank, .albums, .year, .have, .want, .score, .forSale, .lowestPrice: 60
        }
    }

    /// Hidden until shown from the header's menu.
    var hiddenByDefault: Bool { [.rank, .score, .forSale, .lowestPrice].contains(self) }

    /// Whether the column has anything to show for `query`: Albums on the Artists view, and
    /// Score, Why and Rank for a scored list, Format, In Library and Mark for a discography.
    func applies(to query: RecommendationQuery) -> Bool {
        switch self {
        case .albums: query.show == .artists
        case .score, .why, .rank: !query.seed.isDiscography
        case .format, .inLibrary, .mark: query.seed.isDiscography
        default: true
        }
    }

    /// `download` is the state of the newest job of the row's album's release, nil for none.
    func text(_ row: RecommendationRow, download: String?) -> String {
        let album = row.album
        let values = album.community?.values
        switch self {
        case .rank: return number(row.artist?.rank ?? album.rank)
        case .artist:
            return row.artist.map { name($0.name) }
                ?? album.artists.map { name($0.name) }
                .joined(separator: ", ")
        case .albums: return row.artist.map { number($0.albums) } ?? ""
        case .title: return terminalSafe(album.title)
        case .year: return album.year.map(String.init) ?? ""
        case .label: return album.label.map { name($0.name) } ?? ""
        case .styles: return album.styles.map { name($0.name) }.joined(separator: ", ")
        case .format: return album.formats.map(terminalSafe).joined(separator: "; ")
        case .inLibrary: return album.inLibrary ? "Yes" : ""
        case .mark: return album.mark.map(verdictTitle) ?? ""
        case .rating: return ratingText(album.community)
        case .have: return values.map { number($0.have) } ?? ""
        case .want: return values.map { number($0.want) } ?? ""
        case .download: return download ?? ""
        case .why: return album.reasons.first.map { terminalSafe($0.words) } ?? ""
        case .score:
            return (row.artist.map(\.score) ?? album.score).map { String(format: "%.2f", $0) } ?? ""
        case .forSale: return values?.numForSale.map(number) ?? ""
        case .lowestPrice: return values?.lowestPrice.map { String(format: "%.2f", $0) } ?? ""
        }
    }
}

/// A catalog name, or the id's stand-in when the catalog has none.
private func name(_ name: String?) -> String { name.map(terminalSafe) ?? "?" }

/// `4.25 (87)` for a release with values, else the community sync's status: `queued`, `gone`,
/// `failed` or `not_queued`.
private func ratingText(_ community: CommunityValues?) -> String {
    guard let community else { return "" }
    if let values = community.values {
        return String(format: "%.2f", values.ratingAverage) + " (\(number(values.ratingCount)))"
    }
    return community.status.rawValue
}

/// A sort by a column's header, which the window keeps for a list it holds whole (ADR 0218).
struct HeaderSort: Equatable {
    var column: RecommendationColumn
    var ascending: Bool
}

extension RecommendationColumn {
    /// Whether the column's header sorts `query`'s list: only a discography's, which the
    /// window reads whole, and never Download, whose states change as the jobs run.
    func sorts(_ query: RecommendationQuery) -> Bool {
        query.seed.isDiscography && applies(to: query) && self != .download
    }

    /// `rows` in `sort`'s order: empty values last both ways, and the list's own order between
    /// equal ones.
    static func sorted(_ rows: [RecommendationRow], by sort: HeaderSort) -> [RecommendationRow] {
        let keyed = rows.enumerated().map { (offset: $0, row: $1, key: sort.column.key($1)) }
        return keyed.sorted { one, other in
            switch (one.key, other.key) {
            case (nil, nil): return one.offset < other.offset
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?):
                switch a.compare(b) {
                case .orderedSame: return one.offset < other.offset
                case .orderedAscending: return sort.ascending
                case .orderedDescending: return !sort.ascending
                }
            }
        }.map(\.row)
    }

    /// What the column sorts `row` by, nil for an empty value: a number for the numeric
    /// columns (a rating by its average), whether the library has the album for In Library,
    /// and the cell's text for the rest.
    private func key(_ row: RecommendationRow) -> SortKey? {
        let album = row.album
        let values = album.community?.values
        switch self {
        case .rank: return .number(Double(row.artist?.rank ?? album.rank))
        case .albums: return row.artist.map { .number(Double($0.albums)) }
        case .year: return album.year.map { .number(Double($0)) }
        case .inLibrary: return .number(album.inLibrary ? 1 : 0)
        case .rating: return values.map { .number($0.ratingAverage) }
        case .have: return values.map { .number(Double($0.have)) }
        case .want: return values.map { .number(Double($0.want)) }
        case .score: return (row.artist.map(\.score) ?? album.score).map { .number($0) }
        case .forSale: return values?.numForSale.map { .number(Double($0)) }
        case .lowestPrice: return values?.lowestPrice.map { .number($0) }
        case .artist, .title, .label, .styles, .format, .mark, .download, .why:
            let shown = text(row, download: nil)
            return shown.isEmpty ? nil : .text(shown)
        }
    }
}

/// A value a header sort compares: numbers by value, text as the Finder orders names.
private enum SortKey {
    case number(Double)
    case text(String)

    func compare(_ other: SortKey) -> ComparisonResult {
        switch (self, other) {
        case (.number(let a), .number(let b)):
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        case (.text(let a), .text(let b)): a.localizedStandardCompare(b)
        case (.number, .text), (.text, .number):
            preconditionFailure("a column's values are all of one kind")
        }
    }
}
