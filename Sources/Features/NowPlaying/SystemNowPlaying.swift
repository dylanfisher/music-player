import AppKit
import MediaPlayer

/// `NowPlayingCenter` on the system's `MPNowPlayingInfoCenter`, which Control Center reads.
@MainActor
public final class SystemNowPlaying: NowPlayingCenter {
    public init() {}

    public func show(_ info: NowPlayingInfo?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        values[MPMediaItemPropertyArtist] = info.artist
        values[MPMediaItemPropertyAlbumTitle] = info.album
        values[MPMediaItemPropertyPlaybackDuration] = info.durationSeconds
        values[MPMediaItemPropertyArtwork] = info.art.map(Self.artwork)
        center.nowPlayingInfo = values
        center.playbackState = info.isPlaying ? .playing : .paused
    }

    /// Made outside the main actor, since the system may ask for the image on any thread. The
    /// image is decoded already, so answering only wraps it.
    nonisolated private static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        let pixels = CGSize(width: image.width, height: image.height)
        return MPMediaItemArtwork(boundsSize: pixels) { size in
            NSImage(cgImage: image, size: NowPlayingInfo.artSize(pixels, fitting: size))
        }
    }
}
