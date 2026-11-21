import Discogs
import DisplayText
import Foundation
import Recommender

/// What Show Discography offers: the Discogs artists to choose from, or why there are none
/// (ADR 0217).
enum DiscographyChoice: Equatable, Sendable {
    case artists([RecommendationPage.Named])
    case unavailable(String)

    static let variousArtistsText = "Various Artists has no discography"
    static let noReleaseText = "The track isn't tagged with a Discogs release"

    /// `artists` each once, without Various Artists, whose discography the service refuses.
    init(_ artists: [RecommendationPage.Named]) {
        var seen: Set<Int> = []
        let offered = artists.filter {
            $0.id != RecommendationQuery.variousArtistsID && seen.insert($0.id).inserted
        }
        self = offered.isEmpty ? .unavailable(Self.variousArtistsText) : .artists(offered)
    }

    /// A row's artists, which the service sends with their ids.
    init(_ album: RecommendationPage.Album) { self.init(album.artists) }

    /// A track tagged with `release`, through its main artists in this Mac's catalog, which
    /// `artists` reads.
    static func of(
        release: Int?, _ artists: (Int) throws -> [RecommendationPage.Named]?
    ) -> DiscographyChoice {
        guard let release else { return .unavailable(noReleaseText) }
        do {
            guard let found = try artists(release) else {
                return .unavailable("This Mac's Discogs catalog doesn't have release \(release)")
            }
            return DiscographyChoice(found)
        } catch {
            return .unavailable(terminalSafe("Couldn't read the Discogs catalog: \(error)"))
        }
    }

    /// What the owner pasted: an artist as it is, or a release's or master's main artists in
    /// the catalog, which `artists` reads. An artist the catalog hasn't is still asked for by
    /// id; the service answers whether it has it.
    static func of(_ pasted: PastedDiscogsID, _ artists: DiscographyArtists) -> DiscographyChoice {
        do {
            switch pasted {
            case .artist(let id):
                return DiscographyChoice([
                    RecommendationPage.Named(id: id, name: try artists.name(id))
                ])
            case .release(let id):
                guard let found = try artists.release(id) else {
                    return .unavailable("This Mac's Discogs catalog doesn't have release \(id)")
                }
                return DiscographyChoice(found)
            case .master(let id):
                guard let found = try artists.master(id) else {
                    return .unavailable("This Mac's Discogs catalog doesn't have master \(id)")
                }
                return DiscographyChoice(found)
            }
        } catch {
            return .unavailable(terminalSafe("Couldn't read the Discogs catalog: \(error)"))
        }
    }
}

/// The catalog's reads Show Discography makes, so tests can stand in for the catalog.
struct DiscographyArtists {
    var release: (Int) throws -> [RecommendationPage.Named]?
    var master: (Int) throws -> [RecommendationPage.Named]?
    var name: (Int) throws -> String?
}

extension DiscographyArtists {
    /// The reads of the catalog at `url`, opened for each. Without a catalog, a release or
    /// master fails saying so, and an artist has no name, so a pasted artist still opens.
    init(catalogAt url: URL?) {
        let open = { () throws -> Catalog in
            guard let url else { throw NoCatalog() }
            return try Catalog(at: url)
        }
        release = { try open().discographyArtists(release: $0) }
        master = { try open().discographyArtists(master: $0) }
        name = { id in
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Catalog(at: url).artistName(id)
        }
    }
}

/// The app has set no place for this Mac's Discogs catalog.
private struct NoCatalog: Error, CustomStringConvertible {
    var description: String { "no place is set for this Mac's Discogs catalog" }
}
