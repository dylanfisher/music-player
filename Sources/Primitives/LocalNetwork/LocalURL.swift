import Foundation

/// An `http` URL whose host is an address on one local subnet, the only kind the client
/// fetches (ADR 0039). A host name is refused, since it could resolve anywhere.
public struct LocalURL: Hashable, Sendable, CustomStringConvertible {
    public let host: IPAddress
    public let port: UInt16
    /// The path and query, percent-encoded, starting with "/".
    public let target: String
    /// The interface whose subnet holds the host.
    public let interface: NetworkInterface

    /// Why a URL isn't one the app follows.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case notHTTP(String)
        case notAnAddress(String)
        case offSubnet(String, NetworkInterface)
        case otherHost(String)
        case notTheSender(String)
        case notAHost(String)

        public var description: String {
            switch self {
            case .notHTTP(let text): "\(text.debugDescription) isn't a plain http URL"
            case .notAnAddress(let text): "\(text.debugDescription) doesn't name an IP address"
            case .offSubnet(let text, let interface):
                "\(text.debugDescription) is off the subnet of \(interface)"
            case .otherHost(let text):
                "\(text.debugDescription) leaves the host the description came from"
            case .notTheSender(let text):
                "\(text.debugDescription) names a host other than the one that replied"
            case .notAHost(let text):
                "\(text.debugDescription) names a subnet's network or broadcast address, or"
                    + " this Mac's own"
            }
        }
    }

    /// Longest URL text taken.
    static let textCap = 2048

    /// `text` as a URL on `interface`'s subnet: `http`, an IP literal host, no user, no
    /// fragment. A link-local IPv6 host takes the interface as its zone.
    init(_ text: String, on interface: NetworkInterface) throws(Refusal) {
        guard text.utf8.count <= Self.textCap, let parts = URLComponents(string: text),
            parts.scheme?.lowercased() == "http", parts.user == nil, parts.password == nil,
            parts.fragment == nil
        else { throw .notHTTP(String(text.prefix(Self.textCap))) }
        guard var hostText = parts.percentEncodedHost, !hostText.isEmpty else {
            throw .notAnAddress(text)
        }
        if hostText.hasPrefix("[") && hostText.hasSuffix("]") {
            hostText = String(hostText.dropFirst().dropLast())
                .replacingOccurrences(of: "%25", with: "%")
        }
        guard var host = IPAddress(hostText) else { throw .notAnAddress(text) }
        if host.isLinkLocal, case .v6(_, 0) = host { host = host.zoned(interface.index) }
        guard interface.holds(host) else { throw .offSubnet(text, interface) }
        let port = parts.port ?? 80
        guard (1...Int(UInt16.max)).contains(port) else { throw .notHTTP(text) }
        var target = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { target += "?" + query }
        // URLComponents encodes the rest, so this only refuses what it let through.
        guard target.hasPrefix("/"), target.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw .notHTTP(text)
        }
        self.host = host
        self.port = UInt16(port)
        self.target = target
        self.interface = interface
    }

    /// A URL a description names, relative to this one, held to the same host and port.
    public func resolving(_ reference: String) throws(Refusal) -> LocalURL {
        guard let base = URL(string: description),
            let absolute = URL(string: reference, relativeTo: base)?.absoluteString
        else { throw .notHTTP(String(reference.prefix(Self.textCap))) }
        let resolved = try LocalURL(absolute, on: interface)
        guard resolved.host == host, resolved.port == port else { throw .otherHost(reference) }
        return resolved
    }

    /// The `Host` header's value.
    var authority: String { "\(host.urlHost):\(port)" }

    public var description: String { "http://\(authority)\(target)" }
}
