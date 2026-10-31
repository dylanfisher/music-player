import Metadata

/// A stored warning or failure for one file, as the scanner recorded it.
public struct FileIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Problem: Equatable, Sendable {
        /// The file is in the library, with one field read in part or dropped.
        case warning(MetadataWarning.Kind)
        /// The file couldn't be read. An unreadable file that was read before keeps its track.
        case failure(MetadataError.Kind)
    }

    public var path: String
    public var problem: Problem
    /// Byte offset in the file, when the problem is at one place.
    public var offset: Int?
    public var detail: String

    public var description: String {
        let kind =
            switch problem {
            case .warning(let kind): "warning \(kind.rawValue)"
            case .failure(let kind): "failure \(kind.rawValue)"
            }
        return "\(path): \(kind): \(detail)" + (offset.map { " (at byte \($0))" } ?? "")
    }
}
