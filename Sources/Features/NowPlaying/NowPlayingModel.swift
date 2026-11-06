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
    /// The playback problem `message` says, for its details; nil for any other message.
    public private(set) var problem: ShownProblem?
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
        case .trackStarted, .resumed: show(nil)
        case .trackFailed(let url, let entry, let failure):
            show(
                ShownProblem(
                    problem: failure, track: url, entry: entry, trackFormat: format(of: url),
                    headline: "Couldn't play \(url.lastPathComponent): \(failure.message)"))
        case .deviceLost:
            show("The output device went away, so playback paused. Plug it back in to resume.")
        case .deviceReturned: show("The output device is back. Press Play to resume.")
        case .failed(let failure):
            // The output stops on the track it was playing; tracks failing in a row are
            // about the first of them.
            let first = failure.causes.first
            let track = first?.tracks.first ?? currentURL
            show(
                ShownProblem(
                    problem: failure, track: track,
                    entry: first?.entries.first ?? state.currentIndex,
                    trackFormat: track.flatMap(format),
                    headline: "Playback stopped: \(failure.message)"))
        default: break
        }
        guard currentURL != before else { return }
        lookUpTrack()
    }

    private func show(_ message: String?) {
        self.message = message
        problem = nil
    }

    private func show(_ problem: ShownProblem) {
        message = problem.headline
        self.problem = problem
    }

    /// The format of the file at `url`, from the library's row, for a problem's details.
    private func format(of url: URL) -> String? {
        do {
            return try lookup(url.path).map(Self.format)
        } catch {
            logger.error("couldn't read the library's row for \(url.path): \(error)")
            return nil
        }
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
            show("Couldn't read \(url.lastPathComponent) from the library: \(error)")
        }
    }

    public var title: String {
        track?.title ?? currentURL?.deletingPathExtension().lastPathComponent ?? "Not Playing"
    }

    /// "Artist — Album", with whichever the tags have.
    var subtitle: String {
        [track?.artist, track?.album].compactMap { $0 }.joined(separator: " — ")
    }

    /// "96 kHz 24-bit FLAC → ADI-2 DAC: 96 kHz · 32-bit": the file's format, then the device
    /// and what it runs at, once the output says.
    var formatLine: String {
        [sourceFormat, state.outputFormat].compactMap { $0 }.joined(separator: " → ")
    }

    /// "96 kHz 24-bit FLAC": the file's format, from the library's row.
    private var sourceFormat: String? { track.map(Self.format) }

    private static func format(of track: TrackRow) -> String {
        // A DSD rate's name says the format and the depth already.
        guard track.codec != TrackAudio.Codec.dsd.rawValue else {
            return sampleRateText(track.sampleRateHz)
        }
        let bits = track.bitsPerSample.map { " " + bitDepth($0) } ?? ""
        return "\(sampleRateText(track.sampleRateHz))\(bits) \(track.codec.uppercased())"
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
