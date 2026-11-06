/// What went wrong with playback, as an event carries it: the message for the user, the
/// error's full text for the details, and what the app can do about it (ADR 0111).
public struct PlaybackProblem: Sendable, Equatable {
    /// The error's `userMessage`, or its description for an error that isn't a
    /// `PlaybackFailure`, such as a test stand-in's.
    public var message: String
    /// The error's description, which the log and the command line print too.
    public var detail: String
    public var fix: PlaybackFix?

    init(_ error: any Error) {
        detail = "\(error)"
        let failure = error as? any PlaybackFailure
        message = failure?.userMessage ?? detail
        fix = failure?.fix
    }
}
