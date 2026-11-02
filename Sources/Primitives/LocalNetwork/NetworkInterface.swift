import Darwin

/// One address of a network interface that's up, and the subnet it's on.
public struct NetworkInterface: Hashable, Sendable, CustomStringConvertible {
    /// "en0".
    public let name: String
    /// The index a link-local address's zone names.
    public let index: UInt32
    public let address: IPAddress
    /// The netmask or the IPv6 prefix, in bits.
    let prefixLength: Int

    init(name: String, index: UInt32, address: IPAddress, prefixLength: Int) {
        precondition(
            prefixLength >= 0 && prefixLength <= address.bytes.count * 8,
            "a /\(prefixLength) prefix doesn't fit \(address)")
        self.name = name
        self.index = index
        self.address = address
        self.prefixLength = prefixLength
    }

    /// Whether `other` is on this interface's subnet. A link-local IPv6 address is only when
    /// its zone is this interface.
    func holds(_ other: IPAddress) -> Bool {
        switch (address, other) {
        case (.v4(let mine), .v4(let theirs)):
            return samePrefix(mine, theirs)
        case (.v6(let mine, _), .v6(let theirs, let zone)):
            if other.isLinkLocal { return address.isLinkLocal && zone == index }
            return !address.isLinkLocal && samePrefix(mine, theirs)
        default:
            return false
        }
    }

    /// Whether `other` is this subnet's address with the host bits all clear or, for IPv4,
    /// all set. A /31 or /32 has neither.
    func isNetworkOrBroadcast(_ other: IPAddress) -> Bool {
        let bits = other.bytes.count * 8
        guard prefixLength < bits - 1, holds(other) else { return false }
        var clear = true
        var set = true
        for bit in prefixLength..<bits {
            let on = other.bytes[bit / 8] & (0x80 >> UInt8(bit % 8)) != 0
            if on { clear = false } else { set = false }
        }
        if case .v6 = other { return clear }
        return clear || set
    }

    private func samePrefix(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var bits = prefixLength
        for (x, y) in zip(a, b) where bits > 0 {
            let mask: UInt8 = bits >= 8 ? 0xFF : ~(0xFF >> UInt8(bits))
            if x & mask != y & mask { return false }
            bits -= 8
        }
        return true
    }

    public var description: String { "\(name) \(address)/\(prefixLength)" }
}

/// The addresses of the interfaces that are up, running and can multicast now, without
/// loopback and point-to-point links such as a VPN's, which aren't a local subnet.
public func currentInterfaces() throws(LocalNetworkError) -> [NetworkInterface] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { throw .system("getifaddrs", errno: errno) }
    defer { freeifaddrs(first) }
    var found: [NetworkInterface] = []
    var next = first
    while let entry = next?.pointee {
        next = entry.ifa_next
        let flags = Int32(entry.ifa_flags)
        let needed = IFF_UP | IFF_RUNNING | IFF_MULTICAST
        guard flags & needed == needed, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
            let socketAddress = entry.ifa_addr, let mask = entry.ifa_netmask,
            let address = IPAddress(socketAddress), let netmask = IPAddress(mask)
        else { continue }
        let name = String(cString: entry.ifa_name)
        let prefix = netmask.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
        found.append(
            NetworkInterface(
                name: name, index: if_nametoindex(entry.ifa_name), address: address,
                prefixLength: prefix))
    }
    return found
}
