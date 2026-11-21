import Recommender

/// Why the Recommendations window shows no list, or no more of it.
enum ListProblem: Equatable {
    /// The service's address or token isn't set.
    case notSet
    /// The service understood the request and refused it, with its code.
    case refused(ServiceRefusal)
    /// The service stayed busy through every retry.
    case busy
    /// A 404 `unknown_artist`: the service's catalog has no artist of the discography's id.
    case unknownArtist
    /// A 400 `various_artists`: the service refuses Various Artists' discography.
    case variousArtists
    /// Any other error, as its text.
    case failed(String)
}
