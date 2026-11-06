import Metadata

/// An error that can stop playback, with what to tell the user. `userMessage` is a short
/// lowercase clause that reads after "Playback stopped: " or "Couldn't play a.flac: ", with no
/// type name or code; those stay in `description`, which the details show (ADR 0111).
public protocol PlaybackFailure: Error, CustomStringConvertible {
    var userMessage: String { get }
    /// What the app can change so the track plays, or nil when it can't.
    var fix: PlaybackFix? { get }
}

extension PlaybackFailure {
    public var fix: PlaybackFix? { nil }
}

/// A change the app can make for the user so a track that failed plays, then play it again.
public enum PlaybackFix: Sendable, Equatable {
    /// Turn on hog mode for the device with this UID, which DoP needs (phase 22).
    case turnOnHogMode(deviceUID: String)
}

/// The DSD readers throw it for a file they can't parse.
extension MetadataError: PlaybackFailure {}
