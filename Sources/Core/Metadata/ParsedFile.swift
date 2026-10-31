/// A file's metadata, and what reading it cost.
public struct ParsedFile: Sendable {
    public var metadata: TrackMetadata
    /// Every byte read from the file, including the read-ahead around each field.
    public var bytesRead: Int
    /// Read calls, each of which may be a round trip to a NAS.
    public var readCount: Int
}
