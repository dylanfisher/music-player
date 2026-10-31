/// A file's metadata, the fields that couldn't be read as written, and what reading it cost.
public struct ParsedFile: Sendable {
    public var metadata: TrackMetadata
    /// In the order they were found. Empty when every field read cleanly.
    public var warnings: [MetadataWarning]
    /// Every byte read from the file, including the read-ahead around each field.
    public var bytesRead: Int
    /// Read calls, each of which may be a round trip to a NAS.
    public var readCount: Int
}
