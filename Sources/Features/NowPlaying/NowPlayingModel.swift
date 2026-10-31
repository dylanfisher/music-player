import DisplayText
import Foundation
import Library
import Log
import Playback

private let logger = moduleLogger()

/// What the now-playing bar shows, worked out from the engine's updates and the library's row
/// for the current file.
@MainActor
public final class NowPlayingModel {
    public private(set) var state = PlaybackState()
    /// The library's row for the current file, or nil when there's none or the library doesn't
    /// have it.
    public private(set) var track: TrackRow?
    /// The last thing that went wrong, until playback carries on.
    public private(set) var message: String?
    private let lookup: (String) throws -> TrackRow?

    /// `lookup` finds a file's row by path.
    public init(lookup: @escaping (String) throws -> TrackRow?) {
        self.lookup = lookup
    }

    public var currentURL: URL? {
        state.currentIndex.flatMap { state.queue.indices.contains($0) ? state.queue[$0] : nil }
    }

    public var isPlaying: Bool { state.status == .playing }

    public func apply(_ update: PlaybackUpdate) {
        let before = currentURL
        state = update.state
        switch update.event {
        case .trackStarted, .resumed: message = nil
        case .trackFailed(let url, let reason):
            message = "Couldn't play \(url.lastPathComponent): \(reason)"
        case .deviceLost:
            message = "The output device went away, so playback paused. Plug it back in to resume."
        case .deviceReturned: message = "The output device is back. Press Play to resume."
        case .failed(let reason): message = "Playback stopped: \(reason)"
        default: break
        }
        guard currentURL != before else { return }
        track = nil
        guard let url = currentURL else { return }
        do {
            track = try lookup(url.path)
        } catch {
            logger.error("couldn't read the library's row for \(url.path): \(error)")
            message = "Couldn't read \(url.lastPathComponent) from the library: \(error)"
        }
    }

    public var title: String {
        track?.title ?? currentURL?.deletingPathExtension().lastPathComponent ?? "Not Playing"
    }

    /// "Artist — Album", with whichever the tags have.
    public var subtitle: String {
        [track?.artist, track?.album].compactMap { $0 }.joined(separator: " — ")
    }

    /// "96 kHz 24-bit FLAC → ADI-2 DAC: 'lpcm' 2 ch 32-bit int @ 96 kHz, non-mixable, hog mode":
    /// the file's format, then what the output is running, once it says.
    public var formatLine: String {
        let source = track.map { track in
            let bits = track.bitsPerSample.map { " \($0)-bit" } ?? ""
            return "\(kilohertz(Double(track.sampleRateHz))) kHz\(bits) \(track.codec.uppercased())"
        }
        return [source, state.outputFormat].compactMap { $0 }.joined(separator: " → ")
    }

    /// Elapsed and remaining time for the bar, as "1:02" and "-3:40".
    public func times(positionSeconds: Double?) -> (elapsed: String, remaining: String) {
        guard let duration = state.durationSeconds, let position = positionSeconds else {
            return ("", "")
        }
        let elapsed = min(max(0, position), duration)
        return (clock(elapsed), "-" + clock(duration - elapsed))
    }
}
