import DisplayText
import Foundation
import Library
import Log
import Metadata
import Playback
import Settings

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

    var currentURL: URL? {
        state.currentIndex.flatMap { state.queue.indices.contains($0) ? state.queue[$0] : nil }
    }

    var isPlaying: Bool { state.status == .playing }

    func apply(_ update: PlaybackUpdate) {
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
        lookUpTrack()
    }

    /// Reads the current file's row again, after a rescan may have changed its tags.
    public func libraryChanged() {
        lookUpTrack()
    }

    private func lookUpTrack() {
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
    var subtitle: String {
        [track?.artist, track?.album].compactMap { $0 }.joined(separator: " — ")
    }

    /// "96 kHz 24-bit FLAC → ADI-2 DAC: 'lpcm' 2 ch 32-bit int @ 96 kHz, non-mixable, hog mode":
    /// the file's format, then what the output is running, once it says.
    var formatLine: String {
        [sourceFormat, state.outputFormat].compactMap { $0 }.joined(separator: " → ")
    }

    /// "96 kHz 24-bit FLAC": the file's format, from the library's row.
    private var sourceFormat: String? {
        track.map { track in
            // A DSD rate's name says the format and the depth already.
            guard track.codec != TrackAudio.Codec.dsd.rawValue else {
                return sampleRateText(track.sampleRateHz)
            }
            let bits = track.bitsPerSample.map { " " + bitDepth($0) } ?? ""
            return "\(sampleRateText(track.sampleRateHz))\(bits) \(track.codec.uppercased())"
        }
    }

    /// The window's title, `template` filled from the current track: nil with nothing playing,
    /// or when the fields it names are all empty, for the app's name instead.
    func windowTitle(_ template: TitleTemplate) -> String? {
        guard currentURL != nil else { return nil }
        let title = template.fill(value(of:))
        return title.isEmpty ? nil : title
    }

    /// The current track's value for `token`.
    func value(of token: TitleToken) -> String? {
        switch token {
        case .title: title
        case .artist: track?.artist
        case .album: track?.album
        case .albumArtist: track?.albumArtist
        case .composer: track?.composer
        case .genre: track?.genre
        case .year: track?.year.map(String.init)
        case .trackNumber: track?.trackNumber.map(String.init)
        case .discNumber: track?.discNumber.map(String.init)
        case .format: sourceFormat
        }
    }

    /// Elapsed time and the track's length for the bar, as "1:02" and "4:42".
    func times(positionSeconds: Double?) -> (elapsed: String, total: String) {
        guard let duration = state.durationSeconds, let position = positionSeconds else {
            return ("", "")
        }
        return (clock(min(max(0, position), duration)), clock(duration))
    }
}
