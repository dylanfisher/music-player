/// A field that couldn't be read as written. The file still parses: the field is dropped, read in
/// part, or decoded leniently, and the warning says which and where.
public struct MetadataWarning: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// A track or disc number or total that isn't a plain number. Leading digits are kept.
        case badNumber
        /// Text that isn't valid in its declared encoding, decoded as Latin-1 or with U+FFFD.
        case badText
        /// A value its field can't hold, such as a compilation flag that isn't 1 or 0.
        case badValue
        /// An ID3 frame, MP4 item, Vorbis comment or picture that can't be read, and is skipped.
        case unreadableField
        /// An ID3v2.4 frame size written as a plain integer instead of a syncsafe one, as older
        /// iTunes versions did.
        case nonSyncsafeFrameSize
    }

    public var kind: Kind
    /// Byte offset in the file of the field.
    public var offset: Int
    public var detail: String

    public var description: String { "\(detail) (at byte \(offset))" }
}
