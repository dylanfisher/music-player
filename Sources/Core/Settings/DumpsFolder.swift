import Foundation

/// The folder of the Discogs dumps the catalog is imported from (ADR 0130): a path, or on a
/// network share the share's URL and the path inside it, found wherever the share is mounted,
/// as a watched folder is (ADR 0028). The app only reads it.
public struct DumpsFolder: SettingValue {
    /// An absolute path; for a folder on a share, its path inside the share, with no leading
    /// slash, and empty for the share itself.
    public var path: String
    public var share: String?

    init(path: String, share: String? = nil) {
        self.path = path
        self.share = share
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case path, share
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        share = try container.decodeIfPresent(String.self, forKey: .share)
    }

    public static var typeName: String { "a dumps folder (path, optional share)" }
    public static var kind: SettingKind { .dumpsFolder }

    public func problem() -> String? { folderLocationProblem(path: path, share: share) }
}
