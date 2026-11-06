import Foundation
import Playback

/// A playback problem the status bar shows, with what its details need about the track.
public struct ShownProblem: Equatable, Sendable {
    public var problem: PlaybackProblem
    /// The track it's about; nil when the output stopped with nothing loaded.
    public var track: URL?
    /// The track's index into the queue, which a fix plays again.
    public var entry: Int?
    /// "96 kHz 24-bit FLAC", from the library's row; nil when the library has none.
    var trackFormat: String?
    /// What the status bar says.
    var headline: String

    /// Where in `state`'s play order to play the track again once a fix is made: only while
    /// the engine's current entry is still that track, so a fix never interrupts what played
    /// since. Throws why not otherwise.
    public func replayPosition(in state: PlaybackState) throws(ReplayRefusal) -> Int {
        guard let track, let entry else { throw .noTrack }
        guard state.currentIndex == entry, state.queue.indices.contains(entry),
            state.queue[entry] == track,
            let position = state.order.firstIndex(of: entry)
        else { throw .movedOn(track) }
        return position
    }
}

/// Why a fix doesn't play its track again.
public enum ReplayRefusal: Error, Equatable, CustomStringConvertible {
    case noTrack
    case movedOn(URL)

    public var description: String {
        switch self {
        case .noTrack: "the problem isn't about a track in the queue"
        case .movedOn(let url):
            "the queue's current track is no longer \(url.lastPathComponent), the one that failed"
        }
    }
}

/// What the Playback Problem window shows, and Copy puts on the pasteboard, for a bug report.
public struct ProblemReport: Equatable {
    var shown: ShownProblem
    /// What the output last reported, or nil for no output.
    var path: SignalPath?
    /// The device's hog mode setting; nil for a renderer, which has none.
    var hogMode: Bool?
    /// The playback modules' log lines, oldest first; nil until they're read.
    var logLines: [String]?

    /// The modules whose log lines go in, and how far back.
    static let logCategories: Set<String> = ["Playback", "HALOutput", "UPnPOutput"]
    static let logSeconds = 600.0

    public init(_ shown: ShownProblem, path: SignalPath?, hogMode: Bool?) {
        self.shown = shown
        self.path = path
        self.hogMode = hogMode
    }

    var text: String {
        var lines = [shown.headline, ""]
        if let track = shown.track {
            lines.append("Track: \(track.path)")
            lines.append(
                "Format: \(shown.trackFormat ?? "unknown, as the library doesn't list it")")
        }
        let output = signalPathLines(path)
        lines.append(
            "Output: "
                + (output.stages.last.map { stage in
                    "\(stage.title): \(stage.value)"
                        + (stage.note.isEmpty ? "" : " (\(stage.note))")
                } ?? output.badge))
        if let hogMode { lines.append("Hog mode: \(hogMode ? "on" : "off") for this device") }
        lines.append("Error: \(shown.problem.detail)")
        lines += ["", "Log, last \(Int(Self.logSeconds / 60)) minutes:"]
        lines += logLines.map { $0.isEmpty ? ["No lines."] : $0 } ?? ["Reading the log…"]
        return lines.joined(separator: "\n")
    }
}
