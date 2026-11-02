import Foundation

/// One folder replaced by another at the start of a path, for a library that lived at another
/// mount point (ADR 0033).
public struct PathPrefix: Equatable, Sendable {
    public var from: String
    public var to: String

    /// Nil when `from` is empty, which replaces nothing. Trailing slashes are dropped, so
    /// "/Volumes/music/" and "/Volumes/music" are the same folder.
    public init?(from: String, to: String) {
        let from = trimmed(from)
        guard !from.isEmpty else { return nil }
        self.from = from
        self.to = trimmed(to)
    }

    /// The prefix that moves the missing file `miss` under `folder`, the folder the user picked
    /// as where it lives now: the deepest folder above `miss` with `folder`'s name, so picking
    /// `/Volumes/music-1/dsd` for `/Volumes/music/dsd/A/01.dsf` maps `/Volumes/music/dsd`.
    /// When no folder above it has that name, the user picked the file's own folder, renamed.
    public init(locating miss: String, in folder: String) {
        func name(_ path: String) -> String {
            (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        }
        to = trimmed(folder)
        from = (miss as NSString).deletingLastPathComponent
        var above = from
        while above != "/", !above.isEmpty {
            if name(above) == name(to) {
                from = above
                break
            }
            above = (above as NSString).deletingLastPathComponent
        }
    }

    /// `path` with `from` replaced by `to`, only where `from` is the whole path or a folder of
    /// it, so "/Volumes/music" doesn't take "/Volumes/music2". Compared in NFC, as the lookup is.
    public func apply(_ path: String) -> String {
        let nfc = path.precomposedStringWithCanonicalMapping
        let prefix = from.precomposedStringWithCanonicalMapping
        guard nfc == prefix || nfc.hasPrefix(prefix + "/") else { return path }
        return to + nfc.dropFirst(prefix.count)
    }
}

private func trimmed(_ path: String) -> String {
    var path = Substring(path)
    while path.hasSuffix("/") { path = path.dropLast() }
    return String(path)
}
