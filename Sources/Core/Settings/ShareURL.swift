import Darwin
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

    /// Whether `other` has this share's scheme and name, on any host.
    public func hasSameName(as other: ShareURL) -> Bool {
        scheme == other.scheme && name.lowercased() == other.name.lowercased()
    }

    /// Whether `other` is this share on this host, spelled with or without `.local` or a
    /// Bonjour service label (`nas._smb._tcp.local`), as macOS names one host several ways.
    public func isSameShare(as other: ShareURL) -> Bool {
        hasSameName(as: other) && hostName == other.hostName
    }

    /// The host without the suffixes `isSameShare` ignores.
    var hostName: String {
        var name = Substring(host)
        if name.hasSuffix(".local") { name = name.dropLast(".local".count) }
        for service in ["._smb._tcp", "._afpovertcp._tcp", "._nfs._tcp"]
        where name.hasSuffix(service) {
            name = name.dropLast(service.count)
        }
        return String(name)
    }

    /// Whether the host is an IPv4 or IPv6 address rather than a name.
    public var hostIsAddress: Bool {
        var buffer = in6_addr()
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inet_pton(AF_INET, bare, &buffer) == 1 || inet_pton(AF_INET6, bare, &buffer) == 1
    }
}
