import Foundation
import Network

extension IPAddress {
    /// The address as Network.framework takes it; a zone goes by its interface's name.
    public var endpointHost: NWEndpoint.Host {
        switch self {
        case .v4(let bytes):
            guard let address = IPv4Address(Data(bytes)) else {
                preconditionFailure("four bytes are an IPv4 address")
            }
            return .ipv4(address)
        case .v6(let bytes, let zone):
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            if zone != 0, if_indextoname(zone, &name) != nil {
                return NWEndpoint.Host(
                    description.split(separator: "%")[0] + "%" + string(name))
            }
            guard let address = IPv6Address(Data(bytes)) else {
                preconditionFailure("sixteen bytes are an IPv6 address")
            }
            return .ipv6(address)
        }
    }

    /// The address of an endpoint's host; nil for a name.
    init?(_ host: NWEndpoint.Host) {
        switch host {
        case .ipv4(let address): self = .v4(Array(address.rawValue))
        case .ipv6(let address):
            self.init(v6: Array(address.rawValue), zone: UInt32(address.interface?.index ?? 0))
        default: return nil
        }
    }

    /// The address of a connection's other end; nil when it isn't an address and port.
    init?(peerOf connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        self.init(host)
    }
}

/// TCP parameters that never go through a proxy.
public func directTCP() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.preferNoProxies = true
    return parameters
}
