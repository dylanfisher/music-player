/// The local subnets, one per interface address (ADR 0039). The list is passed in, so tests
/// can make interfaces up.
public struct LocalSubnets: Sendable {
    public let interfaces: [NetworkInterface]

    public init(_ interfaces: [NetworkInterface]) {
        self.interfaces = interfaces
    }

    /// The one interface whose subnet holds `address`: the longest prefix, then the first
    /// listed, so a Mac on one LAN by Wi-Fi and Ethernet answers by one of them. Nil when no
    /// subnet holds it.
    public func interface(holding address: IPAddress) -> NetworkInterface? {
        var best: NetworkInterface?
        for candidate in interfaces where candidate.holds(address) {
            if candidate.prefixLength > best?.prefixLength ?? -1 { best = candidate }
        }
        return best
    }
}
