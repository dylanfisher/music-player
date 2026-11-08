/// What one file's tags and container say about it, read without decoding audio. This is what
/// the library index stores for a track.
public struct TrackMetadata: Equatable, Sendable {
    /// Empty when the file has no tags.
    public var tags: TrackTags
    public var audio: TrackAudio
    /// The front cover when the file has one, otherwise the first embedded picture.
    public var art: EmbeddedArt?
    /// Every embedded picture, in file order, for the art viewer; `art` is one of them.
    public var pictures: [EmbeddedPicture] = []
}
