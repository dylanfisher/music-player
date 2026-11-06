import DisplayText
import Foundation

/// What went wrong with playback, as an event carries it: the message for the user, the
/// error's full text for the details, and what the app can do about it (ADR 0111).
public struct PlaybackProblem: Sendable, Equatable {
    /// One reason tracks failed in a row, and the tracks it stopped.
    public struct Cause: Sendable, Equatable {
        public var message: String
        public var fix: PlaybackFix?
        public var tracks: [URL]
    }

    /// The error's `userMessage`, or its description for an error that isn't a
    /// `PlaybackFailure`, such as a test stand-in's.
    public var message: String
    /// The error's description, which the log and the command line print too.
    public var detail: String
    public var fix: PlaybackFix?
    /// For tracks that failed in a row until playback stopped, each cause, in the order it
    /// first came; empty for any other problem.
    public var causes: [Cause]

    /// "3 tracks in a row couldn't play", which a run of failures' message starts with.
    public static func failedInARow(_ count: Int) -> String {
        "\(tracks(count)) in a row couldn't play"
    }

    init(_ error: any Error) {
        detail = "\(error)"
        let failure = error as? any PlaybackFailure
        message = failure?.userMessage ?? detail
        fix = failure?.fix
        causes = (error as? PlaybackError)?.causes ?? []
    }
}
