enum PlaybackError: Error, CustomStringConvertible {
    case noVolume

    var description: String {
        switch self {
        case .noVolume: "this output has no volume control"
        }
    }
}
