import Metadata

/// An error that can stop playback, with what to tell the user. `userMessage` is a short
/// lowercase clause that reads after "Playback stopped: " or "Couldn't play a.flac: ", with no
/// type name or code; those stay in `description`, which the details show (ADR 0111).
public protocol PlaybackFailure: Error, CustomStringConvertible {
    var userMessage: String { get }
}

/// The DSD readers throw it for a file they can't parse.
extension MetadataError: PlaybackFailure {}
