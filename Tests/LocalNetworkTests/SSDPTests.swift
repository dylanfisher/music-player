import Darwin
import Foundation
import Testing

@testable import LocalNetwork

private let renderer = "urn:schemas-upnp-org:device:MediaRenderer:1"
private let lan = interface("en0", 4, "192.168.1.10", 24)
private let receiver = IPAddress("192.168.1.20")!

private func replyText(
    location: String = "http://192.168.1.20:60006/upnp/desc.xml", usn: String = "uuid:a::x",
    status: String = "200 OK"
) -> [UInt8] {
    Array(
        ("HTTP/1.1 \(status)\r\nCACHE-CONTROL: max-age=180\r\nLOCATION: \(location)\r\n"
            + "ST: \(renderer)\r\nUSN: \(usn)\r\n\r\n").utf8)
}

private func gather(_ datagrams: [SSDPDatagram]) -> SSDPSearch.Result {
    SSDPSearch.gather(datagrams, searchTarget: renderer, subnets: LocalSubnets([lan]))
}

@Test func theSearchAsksForRenderers() {
    let text = String(
        decoding: SSDPSearch.request(searchTarget: renderer, waitSeconds: 2), as: UTF8.self)
    #expect(
        text
            == "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\nST: \(renderer)\r\n\r\n")
}

@Test func aReplyFromTheSubnetPointingAtItIsKept() throws {
    let result = gather([
        SSDPDatagram(bytes: replyText(), source: receiver),
        // The same device again, and another search target, are dropped quietly.
        SSDPDatagram(bytes: replyText(), source: receiver),
        SSDPDatagram(
            bytes: Array(
                String(decoding: replyText(usn: "uuid:b"), as: UTF8.self)
                    .replacingOccurrences(of: renderer, with: "upnp:rootdevice").utf8),
            source: receiver),
    ])
    #expect(result.problems == [])
    let reply = try #require(result.replies.first)
    #expect(result.replies.count == 1)
    #expect(reply.location.description == "http://192.168.1.20:60006/upnp/desc.xml")
    #expect(reply.location.interface == lan)
    #expect(reply.usn == "uuid:a::x")
}

@Test func hostileRepliesAreReportedAndIgnored() {
    let offSubnet = IPAddress("192.168.2.20")!
    let oversize = replyText() + Array(repeating: UInt8(ascii: "a"), count: SSDPSearch.replyCap)
    let cases: [(SSDPDatagram, SSDPProblem)] = [
        (SSDPDatagram(bytes: replyText(), source: offSubnet), .offSubnet(offSubnet)),
        (
            SSDPDatagram(bytes: oversize, source: receiver),
            .tooLarge(receiver, bytes: oversize.count)
        ),
        (
            SSDPDatagram(bytes: replyText(location: "http://192.168.2.20/d.xml"), source: receiver),
            .badLocation(receiver, .offSubnet("http://192.168.2.20/d.xml", lan))
        ),
        (
            SSDPDatagram(bytes: replyText(location: "http://192.168.1.21/d.xml"), source: receiver),
            .badLocation(receiver, .notTheSender("http://192.168.1.21/d.xml"))
        ),
        (
            SSDPDatagram(
                bytes: replyText(location: "http://192.168.1.255/d.xml"),
                source: IPAddress("192.168.1.255")!),
            .badLocation(IPAddress("192.168.1.255")!, .notAHost("http://192.168.1.255/d.xml"))
        ),
        (
            SSDPDatagram(
                bytes: replyText(location: "http://192.168.1.0/d.xml"),
                source: IPAddress("192.168.1.0")!),
            .badLocation(IPAddress("192.168.1.0")!, .notAHost("http://192.168.1.0/d.xml"))
        ),
        (
            SSDPDatagram(
                bytes: replyText(location: "http://192.168.1.10/d.xml"),
                source: IPAddress("192.168.1.10")!),
            .badLocation(IPAddress("192.168.1.10")!, .notAHost("http://192.168.1.10/d.xml"))
        ),
        (
            SSDPDatagram(
                bytes: replyText(location: "https://192.168.1.20/d.xml"), source: receiver),
            .badLocation(receiver, .notHTTP("https://192.168.1.20/d.xml"))
        ),
        (
            SSDPDatagram(bytes: replyText(location: "http://evil.example/d.xml"), source: receiver),
            .badLocation(receiver, .notAnAddress("http://evil.example/d.xml"))
        ),
        (
            SSDPDatagram(bytes: replyText(status: "404 Not Found"), source: receiver),
            .malformed(receiver, "it isn't a 200 reply")
        ),
        (
            SSDPDatagram(bytes: Array("HTTP/1.1 200 OK\r\nST: x\r\n\r\n".utf8), source: receiver),
            .malformed(receiver, "it lacks one LOCATION, ST and USN")
        ),
        (
            SSDPDatagram(bytes: Array("HTTP/1.1 200 OK\r\nST: x\r\n".utf8), source: receiver),
            .malformed(receiver, "its head doesn't end")
        ),
        (
            SSDPDatagram(bytes: [0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A], source: receiver),
            .malformed(receiver, "it has the byte 255")
        ),
    ]
    for (datagram, problem) in cases {
        let result = gather([datagram])
        #expect(result.replies == [])
        #expect(result.problems == [problem])
    }
}

@Test func problemsPastTheCapAreCounted() {
    let off = IPAddress("8.8.8.8")!
    let result = gather(Array(repeating: SSDPDatagram(bytes: replyText(), source: off), count: 50))
    #expect(result.problems.count == SSDPSearch.problemCap)
    #expect(result.moreProblems == 50 - SSDPSearch.problemCap)
}

@Test func devicesPastTheCapAreDropped() {
    let result = gather(
        (0..<100).map { SSDPDatagram(bytes: replyText(usn: "uuid:\($0)"), source: receiver) })
    #expect(result.replies.count == SSDPSearch.replyCountCap)
}

/// A UDP socket on 127.0.0.1 that answers each datagram with `replies`, standing in for a
/// renderer, so the real transport runs without a datagram reaching the LAN.
private final class LoopbackResponder: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let heard = Heard()

    init(replies: @escaping @Sendable (UInt16) -> [[UInt8]]) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw LocalNetworkError.system("bind", errno: errno) }
        port = UInt16(bigEndian: address.sin_port)
        let port = port
        let heard = heard
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &fromLength)
                        }
                    }
                }
                guard count > 0 else { return }
                heard.add(Array(buffer[..<count]))
                for reply in replies(port) {
                    _ = reply.withUnsafeBytes { bytes in
                        withUnsafePointer(to: &from) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, bytes.baseAddress, bytes.count, 0, $0, fromLength)
                            }
                        }
                    }
                }
            }
        }
    }

    var requests: [[UInt8]] { heard.all }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

@Test func theUDPTransportSearchesAndGathersOnLoopback() async throws {
    let responder = try LoopbackResponder { port in
        [
            replyText(location: "http://127.0.0.1:\(port)/desc.xml"),
            replyText(location: "http://127.0.0.1:\(port)/desc.xml"),
        ]
    }
    defer { responder.stop() }
    let transport = UDPSearchTransport(destination: IPAddress("127.0.0.1")!, port: responder.port)
    let request = SSDPSearch.request(searchTarget: renderer, waitSeconds: 1)
    // 127.0.0.2 isn't on this Mac, so it can't send; the search goes on from the next one.
    let datagrams = try await transport.search(
        request, from: [loopbackSubnet, loopback], seconds: 0.5)
    #expect(responder.requests == [request])
    // The stand-in is this Mac, so it's judged as a device on a made-up 127/8 subnet.
    let result = SSDPSearch.gather(
        datagrams, searchTarget: renderer, subnets: LocalSubnets([loopbackSubnet]))
    #expect(result.problems == [])
    #expect(
        result.replies.map(\.location.description) == [
            "http://127.0.0.1:\(responder.port)/desc.xml"
        ])
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var datagrams: [[UInt8]] = []

    func add(_ datagram: [UInt8]) { lock.withLock { datagrams.append(datagram) } }

    var all: [[UInt8]] { lock.withLock { datagrams } }
}

@Test func aSearchFailsOnlyWhenNoInterfaceCanSend() async throws {
    let transport = UDPSearchTransport(destination: IPAddress("127.0.0.1")!, port: 9)
    let request = SSDPSearch.request(searchTarget: renderer, waitSeconds: 1)
    await #expect(throws: LocalNetworkError.self) {
        try await transport.search(request, from: [loopbackSubnet], seconds: 0.1)
    }
    await #expect(throws: LocalNetworkError.self) {
        try await transport.search(request, from: [], seconds: 0.1)
    }
}

@Test func aCancelledSearchEndsAtOnce() async throws {
    let transport = UDPSearchTransport(destination: IPAddress("127.0.0.1")!, port: 9)
    let request = SSDPSearch.request(searchTarget: renderer, waitSeconds: 1)
    let started = Date()
    let search = Task { () -> LocalNetworkError? in
        do throws(LocalNetworkError) {
            _ = try await transport.search(request, from: [loopback], seconds: 5)
            return nil
        } catch {
            return error
        }
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    search.cancel()
    #expect(await search.value == .cancelled)
    #expect(Date().timeIntervalSince(started) < 1)
}
