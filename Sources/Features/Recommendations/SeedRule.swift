import Commands
import DisplayText
import Recommender

/// Which seed a command asks for from the selection.
public enum SeedKind: Sendable {
    case album, artist

    var commandTitle: String {
        AppCommands.title(of: self == .album ? .recommendationsForAlbum : .recommendationsForArtist)
    }
}

/// An album of the selection, with the artist and release id the profile sends for it.
typealias SeedAlbum = (title: String, artist: String, releaseID: Int?)

/// The seed `kind` takes from the selection's `albums`: its one album, which has to have a
/// release id, or its albums' one artist. Anything else is the line saying why.
func seed(_ kind: SeedKind, of albums: [SeedAlbum]) -> Result<RecommendationQuery.Seed, SeedProblem>
{
    let fail = { (why: String) in
        Result<RecommendationQuery.Seed, SeedProblem>.failure(
            SeedProblem(text: "\(kind.commandTitle): \(why)"))
    }
    guard let first = albums.first else { return fail("no album is selected") }
    switch kind {
    case .album:
        guard albums.count == 1 else {
            return fail("the selection holds \(number(albums.count)) albums; select one")
        }
        guard let releaseID = first.releaseID else {
            return fail(
                "“\(terminalSafe(first.title))” isn't tagged with one Discogs release on every"
                    + " track")
        }
        return .success(.album(releaseID: releaseID, title: first.title))
    case .artist:
        let artists = Set(albums.map(\.artist))
        guard artists.count == 1 else {
            return fail(
                "the selection holds albums by \(number(artists.count)) artists; select one")
        }
        return .success(.artist(first.artist))
    }
}

/// Why the selection gives no seed, as the status bar says it.
struct SeedProblem: Error, Equatable {
    var text: String
}
