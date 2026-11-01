import Foundation

/// A network share as a volume's remount URL names it, such as `smb://nas.local/music`: the
/// part that stays the same wherever macOS mounts the share (ADR 0028). The user name in a
/// remount URL is dropped, since it doesn't change which share it is.
public struct ShareURL: Equatable, Sendable {
    /// Lowercased: `smb`, `afp` or `nfs`.
    public var scheme: String
    /// Lowercased, without a trailing dot, since DNS names ignore case.
    public var host: String
    /// The share, or for NFS the exported path, without its slashes and percent escapes. Two
    /// spellings that differ only in case are one share, as SMB names are.
    public var name: String

    /// Nil unless `text` is a URL with a scheme, a host and a share.
    public init?(_ text: String) {
        guard let components = URLComponents(string: text), let scheme = components.scheme,
            var host = components.host, !host.isEmpty
        else { return nil }
        let name = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.name = name
    }

    /// Whether `other` is the same share on a host that may be spelled another way, such as
    /// the NAS's IP address instead of its name.
    public func hasSameName(as other: ShareURL) -> Bool {
        scheme == other.scheme && name.lowercased() == other.name.lowercased()
    }

    /// Whether `other` is this share on this host.
    public func isSameShare(as other: ShareURL) -> Bool {
        hasSameName(as: other) && host == other.host
    }
}
