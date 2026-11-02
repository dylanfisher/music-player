enum PlaybackError: Error, CustomStringConvertible {
    case noVolume
    case failedInARow(Int)

    var description: String {
        switch self {
        case .noVolume: "this output has no volume control"
        case .failedInARow(let count): "\(count) tracks in a row couldn't play"
        }
    }
}
