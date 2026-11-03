import Foundation

enum PlaybackError: Error, CustomStringConvertible {
    case noVolume
    case failedInARow(Int)
    /// The queue that was to follow a track no longer has it where it started.
    case startedTrackMissing(URL)

    var description: String {
        switch self {
        case .noVolume: "this output has no volume control"
        case .failedInARow(let count): "\(count) tracks in a row couldn't play"
        case .startedTrackMissing(let url):
            "the library no longer lists \(url.lastPathComponent), so the rest of the queue wasn't loaded"
        }
    }
}
