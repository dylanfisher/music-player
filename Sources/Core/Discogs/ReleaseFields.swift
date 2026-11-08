import Foundation
import Settings

/// Each Discogs field's value for a release and the tracks an album's files are matched to
/// (ADR 0132): the release's own for a release field, the track's for a track field.
struct ReleaseFields {
    /// Where a track sits in the release, as the files hold it.
    struct Place: Equatable {
        var track: CatalogTrack
        /// Counted from 0 in the release's tracks as files hold them, as YATE's
        /// `DISCOGS_RELEASE_ORDINAL_POSITION` is.
        var ordinal: Int
        var disc: Int
        /// Counted from 1 on its disc.
        var number: Int
        var discTrackCount: Int
        /// The heading over the track, which names its side or disc.
        var heading: String?
    }

    let release: CatalogRelease
    let places: [Place]
    let discCount: Int

    /// `tracks` is the release's tracklist as the album's files hold it (`AlbumMatch.tracks`).
    init(_ release: CatalogRelease, tracks: [CatalogTrack]) {
        self.release = release
        let discs = tracks.map { discAndNumber($0.position) }
        let numbered = discs.allSatisfy { $0 != nil }
        let discOf = tracks.indices.map { numbered ? discs[$0]!.disc : 1 }
        let headings = Headings(release.tracks)
        var places: [Place] = []
        for (index, track) in tracks.enumerated() {
            let disc = discOf[index]
            places.append(
                Place(
                    track: track, ordinal: index, disc: disc,
                    number: discOf[..<index].filter { $0 == disc }.count + 1,
                    discTrackCount: discOf.filter { $0 == disc }.count,
                    heading: headings.take(track)))
        }
        self.places = places
        discCount = Set(discOf).count
    }

    /// `field`'s value, with `place` the file's track; nil where Discogs has none, and for a
    /// track field of a file matched to no track.
    func value(_ field: DiscogsField, at place: Place?) -> MappedValue? {
        if field.level == .track, place == nil { return nil }
        let text = { (text: String?) in text.flatMap { $0.isEmpty ? nil : MappedValue.text($0) } }
        let list = { (values: [String]) in values.isEmpty ? nil : MappedValue.list(values) }
        switch field {
        case .releaseID: return .text(String(release.id))
        case .masterID: return text(release.masterID.map { "m\($0)" })
        case .releaseURL: return .text(releaseURL(release.id))
        case .masterURL: return text(release.masterID.map { discogsURL("master", $0) })
        case .album: return text(release.title)
        case .albumArtist: return release.artists.isEmpty ? nil : .artists(release.artists)
        case .albumArtistURL: return list(artistURLs(release.artists))
        case .label: return release.labels.isEmpty ? nil : .names(release.labels.map(\.name))
        case .labelURL:
            return list(unique(release.labels.compactMap { $0.id.map { discogsURL("label", $0) } }))
        case .catalogNumber: return text(release.labels.first?.catalogNumber)
        case .labelCatalogNumbers:
            return list(
                release.labels.compactMap { label in
                    label.catalogNumber.map { "\(label.name): \($0)" }
                })
        case .barcode: return text(release.barcodes.first)
        case .country: return text(release.country)
        case .date: return text(release.released)
        case .genres: return list(release.genres)
        case .styles: return list(release.styles)
        case .media: return list(release.formats.map(mediaText))
        case .compilation:
            return .text(release.artists.contains { $0.name == discogsVarious } ? "1" : "0")
        case .discCount: return .text(String(discCount))
        default: break
        }
        guard let place else { return nil }
        let artists = place.track.artists.isEmpty ? release.artists : place.track.artists
        switch field {
        case .title: return text(place.track.title)
        case .artist: return artists.isEmpty ? nil : .artists(artists)
        case .artistList: return list(artists.map(\.name))
        case .artistNameVariations:
            return list(
                artists.compactMap { artist in artist.nameVariation.map { "\(artist.name)=\($0)" } }
            )
        case .artistURL: return list(artistURLs(artists))
        case .trackNumber: return .text(String(place.number))
        case .trackCount: return .text(String(place.discTrackCount))
        case .discNumber: return .text(String(place.disc))
        case .position: return text(place.track.position)
        case .ordinalPosition: return .text(String(place.ordinal))
        case .discSubtitle: return text(place.heading)
        case .composer, .conductor, .lyricist, .remixer, .producer, .involvedPeople:
            let people = credits(place.track).compactMap { credit -> MappedValue.Person? in
                let roles = CreditRole.split(credit.role)
                if let own = CreditRole.roles(field) {
                    guard roles.contains(where: own.contains) else { return nil }
                    return MappedValue.Person(
                        name: credit.name, nameVariation: credit.nameVariation)
                }
                let rest = roles.filter { !CreditRole.ownFields.contains($0) }
                guard !rest.isEmpty else { return nil }
                return MappedValue.Person(
                    name: credit.name, nameVariation: credit.nameVariation,
                    role: rest.joined(separator: ", "))
            }
            return people.isEmpty ? nil : .people(people)
        default: preconditionFailure("\(field) is a release field, handled above")
        }
    }

    /// The track's own credits, then the release's that cover it: those naming no tracks, and
    /// those whose "A1 to B2, C1" includes its position.
    private func credits(_ track: CatalogTrack) -> [CatalogCredit] {
        track.credits
            + release.credits.filter { credit in
                guard let covered = credit.tracks else { return true }
                return track.position.map { covers(covered, $0) } ?? false
            }
    }

    /// Whether a credit's "A1 to B2, C1" names `position`, by the release's positions in order.
    private func covers(_ covered: String, _ position: String) -> Bool {
        let positions = release.tracks.flatMap { [$0] + $0.subTracks }.compactMap(\.position)
        for part in covered.components(separatedBy: ",") {
            let ends = part.components(separatedBy: " to ").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if ends.count == 2, let first = positions.firstIndex(of: ends[0]),
                let last = positions.firstIndex(of: ends[1]), first <= last
            {
                if positions[first...last].contains(position) { return true }
            } else if ends.count == 1, ends[0] == position {
                return true
            }
        }
        return false
    }
}

/// The Discogs page of release `id`: the one address the release URL tag and every Open on
/// Discogs use.
func releaseURL(_ id: Int) -> String { discogsURL("release", id) }

/// A Discogs page's address, as YATE writes the `DISCOGS_*_URL` keys.
private func discogsURL(_ kind: String, _ id: Int) -> String {
    "https://www.discogs.com/\(kind)/\(id)"
}

private func artistURLs(_ artists: [CatalogArtistCredit]) -> [String] {
    unique(artists.compactMap { $0.id.map { discogsURL("artist", $0) } })
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

/// The disc and track a position names when it has a disc, as "CD2-4" or "2-4" do; nil for
/// "A1", "3" or "11.a".
private func discAndNumber(_ position: String?) -> (disc: Int, track: Int)? {
    guard let position else { return nil }
    let parts = position.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let disc = parts[0].drop { !$0.isNumber }
    guard parts[0].prefix(while: { !$0.isNumber }).allSatisfy(\.isLetter),
        let discNumber = Int(disc), let track = Int(parts[1])
    else { return nil }
    return (discNumber, track)
}

/// The heading over each row of a release's tracklist, handed out in order, so a track that
/// appears twice gets each heading once.
private final class Headings {
    private var rows: [(track: CatalogTrack, heading: String?)] = []

    init(_ tracks: [CatalogTrack]) {
        var heading: String?
        for row in tracks {
            switch row.kind {
            case .heading: heading = row.title
            case .track: rows.append((row, heading))
            case .index:
                rows.append((row, heading))
                rows += row.subTracks.map { ($0, heading) }
            }
        }
    }

    func take(_ track: CatalogTrack) -> String? {
        guard let index = rows.firstIndex(where: { $0.track == track }) else { return nil }
        return rows.remove(at: index).heading
    }
}
