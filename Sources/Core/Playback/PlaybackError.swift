import Foundation

enum PlaybackError: PlaybackFailure {
    case noVolume
    /// The tracks that failed one after another until the engine stopped, in order.
    case failedInARow([FailedTrack])
    /// The queue that was to follow a track no longer has it where it started.
    case startedTrackMissing(URL)

    var description: String {
        switch self {
        case .noVolume: "this output has no volume control"
        case .failedInARow(let tracks):
            PlaybackProblem.failedInARow(tracks.count) + ": "
                + tracks.map { "\($0.url.lastPathComponent): \($0.problem.detail)" }
                .joined(separator: "; ")
        case .startedTrackMissing(let url):
            "the library no longer lists \(url.lastPathComponent), so the rest of the queue wasn't loaded"
        }
    }

    /// For tracks failing in a row, their one cause, or how many there were.
    var userMessage: String {
        switch self {
        case .failedInARow(let tracks):
            PlaybackProblem.failedInARow(tracks.count)
                + (causes.count == 1
                    ? ": \(causes[0].message)" : ", for \(causes.count) different reasons")
        case .noVolume, .startedTrackMissing: description
        }
    }

    /// The fix every cause has, which makes every track play; nil when any differs or has none.
    var fix: PlaybackFix? {
        let fixes = causes.map(\.fix)
        guard let first = fixes.first, fixes.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// The failures in a row grouped by their message and fix, in the order each first came.
    var causes: [PlaybackProblem.Cause] {
        guard case .failedInARow(let tracks) = self else { return [] }
        var causes: [PlaybackProblem.Cause] = []
        for track in tracks {
            if let index = causes.firstIndex(where: {
                $0.message == track.problem.message && $0.fix == track.problem.fix
            }) {
                causes[index].tracks.append(track.url)
            } else {
                causes.append(
                    PlaybackProblem.Cause(
                        message: track.problem.message, fix: track.problem.fix, tracks: [track.url]
                    ))
            }
        }
        return causes
    }
}

/// A track that couldn't play, and why.
struct FailedTrack: Sendable, Equatable {
    var url: URL
    var problem: PlaybackProblem
}
