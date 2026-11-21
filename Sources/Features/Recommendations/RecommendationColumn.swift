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
