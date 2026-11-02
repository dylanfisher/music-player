import Darwin
import Foundation

/// SSDP over a UDP socket. The app passes SSDP's multicast group as `destination`; tests pass a
/// stand-in on loopback, so no test sends a datagram onto the LAN.
public struct UDPSearchTransport: SSDPTransport {
    let destination: IPAddress
    let port: UInt16
    /// Most datagrams one search reads; the rest are left unread.
    static let datagramCap = 256

    public init(destination: IPAddress, port: UInt16) {
        self.destination = destination
        self.port = port
    }

    /// IPv4 only: the request goes out of each IPv4 interface in turn, with a TTL of 1 so it
    /// stays on the subnet.
    public func search(_ request: [UInt8], from interfaces: [NetworkInterface], seconds: Double)
        async throws(LocalNetworkError) -> [SSDPDatagram]
    {
        guard case .v4(let group) = destination else {
            throw .malformed("SSDP searches only over IPv4")
        }
        let sources = interfaces.compactMap { interface -> in_addr? in
            guard case .v4(let bytes) = interface.address else { return nil }
            return bytes.withUnsafeBytes { $0.load(as: in_addr.self) }
        }
        let target = group.withUnsafeBytes { $0.load(as: in_addr.self) }
        let port = port
        let outcome = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(
                    returning: Result { () throws(LocalNetworkError) in
                        try exchange(
                            request, to: target, port: port, from: sources, seconds: seconds)
                    })
            }
        }
        return try outcome.get()
    }
}

/// Sends and reads on one blocking socket, on its own thread, until the deadline.
private func exchange(
    _ request: [UInt8], to target: in_addr, port: UInt16, from sources: [in_addr], seconds: Double
) throws(LocalNetworkError) -> [SSDPDatagram] {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw .system("socket", errno: errno) }
    defer { close(fd) }
    var ttl: UInt8 = 1
    guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1)) == 0 else {
        throw .system("setsockopt IP_MULTICAST_TTL", errno: errno)
    }
    var to = sockaddr_in()
    to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    to.sin_family = sa_family_t(AF_INET)
    to.sin_port = port.bigEndian
    to.sin_addr = target
    for var source in sources {
        guard
            setsockopt(
                fd, IPPROTO_IP, IP_MULTICAST_IF, &source, socklen_t(MemoryLayout<in_addr>.size))
                == 0
        else { throw .system("setsockopt IP_MULTICAST_IF", errno: errno) }
        let sent = request.withUnsafeBytes { bytes in
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        fd, bytes.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == request.count else { throw .system("sendto", errno: errno) }
    }
    var found: [SSDPDatagram] = []
    // One byte past the cap, so a datagram over it shows as over it.
    var buffer = [UInt8](repeating: 0, count: SSDPSearch.replyCap + 1)
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while found.count < UDPSearchTransport.datagramCap {
        let left = deadline - ProcessInfo.processInfo.systemUptime
        guard left > 0 else { break }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, Int32((left * 1000).rounded(.up)))
        if ready < 0 {
            if errno == EINTR { continue }
            throw .system("poll", errno: errno)
        }
        guard ready > 0 else { break }
        var from = sockaddr_storage()
        var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &fromLength)
                }
            }
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw .system("recvfrom", errno: errno)
        }
        let source = withUnsafePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPAddress($0) }
        }
        guard let source else { continue }
        found.append(SSDPDatagram(bytes: Array(buffer[..<count]), source: source))
    }
    return found
}
