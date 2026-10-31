/// Why a file's metadata couldn't be read, and where in the file the problem is.
public struct MetadataError: Error, Equatable, CustomStringConvertible {
    public enum Kind: String, CaseIterable, Sendable {
        /// The file couldn't be opened or read.
        case unreadable
        /// Empty, or not one of the formats this reads.
        case unrecognizedFormat
        /// A length, count or value that the format doesn't allow.
        case malformed
        /// Valid, but uses a feature or codec this doesn't read.
        case unsupported
    }

    public var path: String
    public var kind: Kind
    /// Byte offset in the file, when the problem is at one place.
    public var offset: Int?
    public var detail: String

    public var description: String {
        "\(path): \(detail)" + (offset.map { " (at byte \($0))" } ?? "")
    }
}
