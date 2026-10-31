/// Where a picture sits in its file, so the scanner can record it without reading it and the UI
/// can load it later with `readArt(_:at:)`.
public struct EmbeddedArt: Equatable, Sendable {
    /// Byte offset of the image in the file.
    public var offset: Int
    /// The image's length in the file. For an unsynchronised ID3 frame this is longer than the
    /// image, by one byte per escape.
    public var byteCount: Int
    /// As the file states it, for example "image/jpeg". ID3v2.2's "JPG" and "PNG" are mapped.
    public var mimeType: String
    /// The bytes carry ID3 unsynchronisation, which `readArt` removes.
    public var unsynchronised: Bool
}
