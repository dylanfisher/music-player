import Foundation

/// The folder of the Discogs dumps the catalog is imported from (ADR 0130): a path, or on a
/// network share the share's URL and the path inside it, found wherever the share is mounted,
/// as a watched folder is (ADR 0028). The app only reads it.
public typealias DumpsFolder = SettingFolder<DumpsFolderRole>

public enum DumpsFolderRole: FolderRole {
    public static var typeName: String { "a dumps folder (path, optional share)" }
    public static var kind: SettingKind { .dumpsFolder }
}
