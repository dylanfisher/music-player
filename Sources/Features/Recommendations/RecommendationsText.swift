import DisplayText
import Foundation
import Recommender

/// What the status bar says once the service has kept the profile: "Sent 6,541 albums, 1,741
/// with a release id; 12 newly queued for the community sync".
func profileSentSummary(_ receipt: ProfileReceipt) -> String {
    "Sent \(count(receipt.albums, "album")), \(number(receipt.withReleaseID)) with a release id;"
        + " \(number(receipt.queued)) newly queued for the community sync"
}

/// What a pending read says: a seed list's first read computes it.
func pendingText(_ seed: RecommendationQuery.Seed) -> String {
    switch seed {
    case .library: "Reading the list…"
    case .album(_, let title):
        "Computing the list for \(terminalSafe(title)), which takes about half a minute the first"
            + " time"
    case .artist(let name):
        "Computing the list for \(terminalSafe(name)), which takes about half a minute the first"
            + " time"
    }
}

/// The pop-up's title for `seed`.
func seedTitle(_ seed: RecommendationQuery.Seed) -> String {
    switch seed {
    case .library: "Library"
    case .album(_, let title): "Album: \(terminalSafe(title))"
    case .artist(let name): "Artist: \(terminalSafe(name))"
    }
}

/// The Sort pop-up's title for `sort`, named for its column.
func sortTitle(_ sort: RecommendationQuery.Sort) -> String {
    switch sort {
    case .score: "By \(RecommendationColumn.score.title)"
    case .rating: "By \(RecommendationColumn.rating.title)"
    case .have: "By \(RecommendationColumn.have.title)"
    case .want: "By \(RecommendationColumn.want.title)"
    case .wantHave: "By Want per Have"
    }
}

/// What the window says in place of the list, and what to do about it.
func problemText(_ problem: ListProblem, seed: RecommendationQuery.Seed) -> String {
    switch problem {
    case .notSet: return "Set music-recommender's address and token in Settings."
    case .busy:
        return "The service is busy computing other lists. Try again in a minute."
    case .failed(let text): return text
    case .refused(let refusal):
        switch refusal.code {
        case .noProfile:
            return "The service has no library profile yet. Send it, and the list is scored"
                + " from it in a few minutes."
        case .noCatalog:
            return "The service has no Discogs catalog, or one from another version of the"
                + " service. Import the dumps on the service, then try again."
        case .noList:
            return "The library's list hasn't been scored yet. It is scored after a profile"
                + " or a catalog arrives; try again in a few minutes."
        case .outOfDate where refusal.rebuilding == true:
            return "The library's list is being scored again. This window asks again every"
                + " 30 seconds."
        case .outOfDate:
            return "The library's list was scored from another catalog or profile, and no"
                + " scoring is running. The service's status page shows what it was last"
                + " scored from."
        case .noSeed:
            switch seed {
            case .album(let releaseID, let title):
                return "The service's profile has no album tagged with release \(releaseID)"
                    + " (\(terminalSafe(title))), or its catalog doesn't have that release."
                    + " Send the library profile if the album was tagged since."
            case .artist(let name):
                return "The service's profile has no album by \(terminalSafe(name)) tagged"
                    + " with a release its catalog has."
            case .library: return "\(refusal)"
            }
        default: return "\(refusal)"
        }
    }
}

/// The list's facts, for the window's footer: the catalog set, when it was scored, its seed
/// albums and candidates.
func factsText(_ facts: RecommendationPage.Facts) -> String {
    let scored = DateFormatter.localizedString(
        from: Date(timeIntervalSince1970: TimeInterval(facts.computedAt)), dateStyle: .medium,
        timeStyle: .short)
    return "Catalog \(terminalSafe(facts.catalogSet)), scored \(scored) from"
        + " \(count(facts.seeds, "album")) of the library; \(number(facts.candidates))"
        + " candidates"
}

/// Every reason of `album`, a line each, for the row's tooltip and the detail line.
func reasonsText(_ album: RecommendationPage.Album) -> String {
    album.reasons.map { terminalSafe($0.words) }.joined(separator: "\n")
}
