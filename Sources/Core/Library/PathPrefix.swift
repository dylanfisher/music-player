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

    /// `path` with `from` replaced by `to`, only where `from` is the whole path or a folder of
    /// it, so "/Volumes/music" doesn't take "/Volumes/music2". Compared in NFC, as the lookup is.
    func apply(_ path: String) -> String {
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
