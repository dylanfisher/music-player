import Darwin

/// An IPv4 or IPv6 address as bytes, never a host name. An IPv6 address keeps its zone, the
/// index of the interface it belongs to, which a link-local address needs to mean anything.
public enum IPAddress: Hashable, Sendable, CustomStringConvertible {
    /// Four bytes.
    case v4([UInt8])
    /// Sixteen bytes, and the interface index; 0 is no zone.
    case v6([UInt8], zone: UInt32)

    /// Parses a literal, "192.168.1.20", "fe80::1%en0" or "fe80::1%4"; nil for anything else,
    /// a host name included. An IPv4-mapped IPv6 address is the IPv4 address.
    public init?(_ text: String) {
        var parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let literal = String(parts.removeFirst())
        var four = in_addr()
        if parts.isEmpty, inet_pton(AF_INET, literal, &four) == 1 {
            self = .v4(withUnsafeBytes(of: &four) { Array($0) })
            return
        }
        var six = in6_addr()
        guard inet_pton(AF_INET6, literal, &six) == 1 else { return nil }
        var zone: UInt32 = 0
        if let name = parts.first {
            guard !name.isEmpty else { return nil }
            zone = UInt32(name) ?? if_nametoindex(String(name))
            guard zone != 0 else { return nil }
        }
        self.init(v6: withUnsafeBytes(of: &six) { Array($0) }, zone: zone)
    }

    /// An IPv6 address, or the IPv4 address it maps.
    init(v6 bytes: [UInt8], zone: UInt32) {
        precondition(bytes.count == 16, "an IPv6 address is 16 bytes")
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            self = .v4(Array(bytes[12...]))
        } else {
            self = .v6(bytes, zone: zone)
        }
    }

    /// The address a socket address holds; nil for any other family.
    init?(_ address: UnsafePointer<sockaddr>) {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let inet = UnsafeRawPointer(address).load(as: sockaddr_in.self)
            self = .v4(withUnsafeBytes(of: inet.sin_addr) { Array($0) })
        case AF_INET6:
            let inet6 = UnsafeRawPointer(address).load(as: sockaddr_in6.self)
            self.init(
                v6: withUnsafeBytes(of: inet6.sin6_addr) { Array($0) }, zone: inet6.sin6_scope_id)
        default:
            return nil
        }
    }

    public var bytes: [UInt8] {
        switch self {
        case .v4(let bytes), .v6(let bytes, _): bytes
        }
    }

    /// `fe80::/10`, which means something only on one interface.
    var isLinkLocal: Bool {
        guard case .v6(let bytes, _) = self else { return false }
        return bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
    }

    /// The same address with `zone`, for a link-local address that came without one.
    func zoned(_ zone: UInt32) -> IPAddress {
        guard case .v6(let bytes, _) = self else { return self }
        return .v6(bytes, zone: zone)
    }

    /// The literal, with the zone as an index: "fe80::1%4".
    public var description: String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch self {
        case .v4(let bytes):
            _ = bytes.withUnsafeBytes {
                inet_ntop(AF_INET, $0.baseAddress, &text, socklen_t(text.count))
            }
            return string(text)
        case .v6(let bytes, let zone):
            _ = bytes.withUnsafeBytes {
                inet_ntop(AF_INET6, $0.baseAddress, &text, socklen_t(text.count))
            }
            return string(text) + (zone == 0 ? "" : "%\(zone)")
        }
    }

    /// As a URL's or a `Host` header's host: an IPv6 address in brackets, its zone as `%25`.
    var urlHost: String {
        switch self {
        case .v4: description
        case .v6: "[" + description.replacingOccurrences(of: "%", with: "%25") + "]"
        }
    }
}

/// The text of a NUL-terminated C buffer.
func string(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
