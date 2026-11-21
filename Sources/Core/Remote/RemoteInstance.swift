import LocalNetwork

/// A running app with the web remote on, as its Bonjour advert names it (ADR 0214): its random
/// ID, its computer's name, its `.local` host name, its addresses on this Mac's subnets and its
/// port. The advert's TXT record carries all but the name, since `NWBrowser` gives neither
/// addresses nor port without a resolve per service.
struct RemoteInstance: Encodable, Equatable, Sendable {
    static let serviceType = "_music-player._tcp"
    /// A TXT entry holds 255 bytes, `addr=` included.
    static let addressBytes = 250

    var id: String
    var name: String
    /// "Studio", reached as "studio.local".
    var host: String
    var addresses: [String]
    var port: UInt16

    init(id: String, name: String, host: String, addresses: [String], port: UInt16) {
        self.id = id
        self.name = name
        self.host = host
        self.addresses = addresses
        self.port = port
    }

    private enum Key {
        static let id = "id"
        static let host = "host"
        static let port = "port"
        static let addresses = "addr"
    }

    /// What this instance advertises: as many addresses as fit, IPv4 first.
    var advert: BonjourAdvert {
        var listed: [String] = []
        var bytes = 0
        for address in addresses {
            let added = address.utf8.count + (listed.isEmpty ? 0 : 1)
            guard bytes + added <= Self.addressBytes else { break }
            listed.append(address)
            bytes += added
        }
        return BonjourAdvert(
            name: name, type: Self.serviceType, port: port,
            txt: [
                Key.id: id, Key.host: host, Key.port: "\(port)",
                Key.addresses: listed.joined(separator: ","),
            ])
    }

    /// The instance an advert from the LAN names, with only the addresses on `subnets`; nil,
    /// with why, for one whose TXT record isn't an instance's. Anyone on the LAN can advertise,
    /// so nothing in it is trusted further than this.
    static func parse(_ found: BonjourFound, subnets: LocalSubnets) -> Result<
        RemoteInstance, Refusal
    > {
        let txt = found.txt
        guard let id = txt[Key.id], isInstanceID(id) else { return .failure(.init("its ID")) }
        guard let host = txt[Key.host], isHostLabel(host) else {
            return .failure(.init("its host name"))
        }
        guard let text = txt[Key.port], text.utf8.count <= 5, text.utf8.allSatisfy(isDigit),
            let port = UInt16(text), port > 0
        else { return .failure(.init("its port")) }
        // A zone is an index on the advertiser's Mac, which means nothing on this one.
        let addresses = (txt[Key.addresses] ?? "").split(separator: ",")
            .filter { !$0.contains("%") }.compactMap { IPAddress(String($0)) }
            .filter { subnets.interface(holding: $0) != nil }
        guard !addresses.isEmpty else { return .failure(.init("an address on this subnet")) }
        return .success(
            RemoteInstance(
                id: id, name: found.name, host: host, addresses: addresses.map(\.description),
                port: port))
    }

    struct Refusal: Error, Equatable {
        var missing: String
        init(_ missing: String) { self.missing = missing }
    }

    /// The origins a page from this instance has, lowercased: one per address and its
    /// `.local` name.
    var origins: [String] {
        (addresses.compactMap { IPAddress($0)?.urlHost } + [localName]).map(origin)
    }

    var localName: String { dotLocal(host) }

    /// The origin of a page from this instance by `urlHost`, an address or its `.local` name.
    func origin(_ urlHost: String) -> String { "http://\(urlHost):\(port)".lowercased() }
}

/// The `.local` name Bonjour gives `host`: "studio.local".
func dotLocal(_ host: String) -> String { "\(host.lowercased()).local" }

/// 32 lowercase hex digits, as `RemoteService` makes an instance's ID.
func isInstanceID(_ text: String) -> Bool {
    text.utf8.count == 32
        && text.utf8.allSatisfy { isDigit($0) || (0x61...0x66).contains($0) }
}

/// A DNS label: letters, digits and hyphens, 1 to 63 of them, not starting or ending in a
/// hyphen.
func isHostLabel(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    return (1...63).contains(bytes.count) && bytes.first != 0x2D && bytes.last != 0x2D
        && bytes.allSatisfy {
            isDigit($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D
        }
}

private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
