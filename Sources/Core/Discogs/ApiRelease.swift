import Foundation
import HTTPSClient

/// A release as the Discogs API's `/releases/{id}` returns it: the fields the catalog keeps and
/// the images, by the types the API documents. Other keys are ignored, since Discogs adds
/// fields; a key of the wrong type fails the decode (ADR 0138).
struct ApiRelease: Decodable {
    struct Artist: Decodable {
        var id: Int?
        var name: String
        var anv: String?
        var join: String?
        var role: String?
        var tracks: String?
    }

    struct Label: Decodable {
        var id: Int?
        var name: String
        var catno: String?
    }

    struct Format: Decodable {
        var name: String
        /// A number as text, as the dumps write it.
        var qty: String?
        var text: String?
        var descriptions: [String]?
    }

    struct Identifier: Decodable {
        var type: String
        var value: String?
    }

    struct Track: Decodable {
        var position: String?
        var title: String
        var duration: String?
        var artists: [Artist]?
        var extraartists: [Artist]?
        var subTracks: [Track]?

        private enum CodingKeys: String, CodingKey {
            case position, title, duration, artists, extraartists
            case subTracks = "sub_tracks"
        }
    }

    struct Image: Decodable {
        var type: String?
        var uri: String?
    }

    var id: Int
    var title: String
    var masterID: Int?
    var country: String?
    var released: String?
    var artists: [Artist]?
    var labels: [Label]?
    var formats: [Format]?
    var genres: [String]?
    var styles: [String]?
    var identifiers: [Identifier]?
    var extraartists: [Artist]?
    var tracklist: [Track]?
    var images: [Image]?

    private enum CodingKeys: String, CodingKey {
        case id, title, country, released, artists, labels, formats, genres, styles
        case identifiers, extraartists, tracklist, images
        case masterID = "master_id"
    }
}

/// A release the API returned: what the catalog would hold for it, and its primary image.
public struct FetchedRelease: Equatable, Sendable {
    public internal(set) var release: CatalogRelease
    /// Discogs gives images only to a request with a token.
    var primaryImage: URL?
}

/// Limits on a release from the API, which is input from the network.
enum ApiLimits {
    static let tracklistRows = 2_000
    /// An index track's sub-tracks, and theirs: the dumps nest one level.
    static let subTrackDepth = 3
    static let stringCharacters = 2_000
}

extension ApiRelease {
    /// The release as the catalog would hold it from the dump, by the dump parser's rules:
    /// text trimmed, empty text as none, a master of 0 as none, a row with sub-tracks an index
    /// track and one with no position and no duration a heading. Throws when its id isn't
    /// `requested` or it passes a limit. An image that isn't https on `imageHost` is dropped.
    func fetched(requested: Int, imageHost: String) throws -> FetchedRelease {
        guard id == requested else {
            throw DiscogsAPIError.malformed("release \(requested) came back as \(id)")
        }
        var rows = 0
        let tracks = try converted(tracklist ?? [], depth: 1, rows: &rows)
        let release = CatalogRelease(
            id: id, masterID: masterID.flatMap { $0 > 0 ? $0 : nil }, title: try trimmed(title),
            artists: try (artists ?? []).map { try $0.credit() },
            labels: try (labels ?? []).map { label in
                CatalogRelease.Label(
                    id: label.id, name: try trimmed(label.name),
                    catalogNumber: try nonEmpty(label.catno))
            },
            formats: try (formats ?? []).map { format in
                CatalogRelease.Format(
                    name: try trimmed(format.name), quantity: format.qty.flatMap { Int($0) },
                    text: try nonEmpty(format.text),
                    descriptions: try (format.descriptions ?? []).compactMap(nonEmpty))
            },
            country: try nonEmpty(country), released: try nonEmpty(released),
            genres: try (genres ?? []).compactMap(nonEmpty),
            styles: try (styles ?? []).compactMap(nonEmpty),
            barcodes: try (identifiers ?? []).filter { $0.type == DumpParser.barcodeType }
                .compactMap { try nonEmpty($0.value) },
            credits: try (extraartists ?? []).map { try $0.roleCredit() }, tracks: tracks)
        return FetchedRelease(release: release, primaryImage: primaryImage(on: imageHost))
    }

    private func converted(_ tracks: [Track], depth: Int, rows: inout Int)
        throws -> [CatalogTrack]
    {
        guard depth <= ApiLimits.subTrackDepth || tracks.isEmpty else {
            throw DiscogsAPIError.malformed(
                "sub-tracks nest deeper than \(ApiLimits.subTrackDepth)")
        }
        var converted: [CatalogTrack] = []
        for track in tracks {
            rows += 1
            guard rows <= ApiLimits.tracklistRows else {
                throw DiscogsAPIError.malformed(
                    "the tracklist has over \(ApiLimits.tracklistRows) rows")
            }
            let subTracks = try self.converted(track.subTracks ?? [], depth: depth + 1, rows: &rows)
            let position = try nonEmpty(track.position)
            let seconds = try track.duration.flatMap { CatalogTrack.seconds(try trimmed($0)) }
            let kind = CatalogTrack.kind(
                position: position, durationSeconds: seconds, hasSubTracks: !subTracks.isEmpty)
            converted.append(
                CatalogTrack(
                    kind: kind, position: position, title: try trimmed(track.title),
                    durationSeconds: seconds,
                    artists: try (track.artists ?? []).map { try $0.credit() },
                    credits: try (track.extraartists ?? []).map { try $0.roleCredit() },
                    subTracks: subTracks))
        }
        return converted
    }

    /// The image of type primary, else the first, when it's https on `host`.
    private func primaryImage(on host: String) -> URL? {
        let images = images ?? []
        guard let image = images.first(where: { $0.type == "primary" }) ?? images.first,
            let text = image.uri, let url = URL(string: text),
            HTTPSClient.allows(url, hosts: [host])
        else { return nil }
        return url
    }
}

extension ApiRelease.Artist {
    func credit() throws -> CatalogArtistCredit {
        CatalogArtistCredit(
            id: id, name: try trimmed(name), nameVariation: try nonEmpty(anv),
            join: try nonEmpty(join))
    }

    func roleCredit() throws -> CatalogCredit {
        CatalogCredit(
            id: id, name: try trimmed(name), nameVariation: try nonEmpty(anv),
            role: try nonEmpty(self.role) ?? "", tracks: try nonEmpty(tracks))
    }
}

/// `text` trimmed as the dump parser trims it, refused past `ApiLimits.stringCharacters`.
private func trimmed(_ text: String) throws -> String {
    guard text.count <= ApiLimits.stringCharacters else {
        throw DiscogsAPIError.malformed("a text is over \(ApiLimits.stringCharacters) characters")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `text` trimmed, or nil when it's missing or empty.
private func nonEmpty(_ text: String?) throws -> String? {
    guard let text else { return nil }
    let trimmed = try trimmed(text)
    return trimmed.isEmpty ? nil : trimmed
}
