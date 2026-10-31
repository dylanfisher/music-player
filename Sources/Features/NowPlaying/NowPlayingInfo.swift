import CoreGraphics

/// What Now Playing shows for the current track.
public struct NowPlayingInfo: Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    var durationSeconds: Double?
    /// Seconds into the track when this is shown. The system adds `rate` times the time since,
    /// so it's set again only when that sum would be wrong.
    var elapsedSeconds: Double
    var isPlaying: Bool
    /// Already decoded at `MediaControls.artPixels`.
    var art: CGImage?

    var rate: Double { isPlaying ? 1 : 0 }

    /// Whether only the time differs, which the system works out for itself.
    func sameApartFromTime(as other: NowPlayingInfo) -> Bool {
        var other = other
        other.elapsedSeconds = elapsedSeconds
        return self == other
    }

    /// The largest size of `image`'s shape that fits in `box`, for the size the system asks
    /// the art for. Never larger than the image, which would only be scaled up.
    static func artSize(_ image: CGSize, fitting box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(1, box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
