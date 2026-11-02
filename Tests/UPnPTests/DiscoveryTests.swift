import Foundation
import LocalNetwork
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import UPnP

private let loopback = NetworkInterface(
    name: "lo0", index: 1, address: IPAddress("127.0.0.1")!, prefixLength: 8)

/// Hands back made-up replies without sending anything.
struct FakeSSDP: SSDPTransport {
    var datagrams: [SSDPDatagram]

    func search(_ request: [UInt8], from interfaces: [NetworkInterface], seconds: Double)
        async throws(LocalNetworkError) -> [SSDPDatagram]
    {
        datagrams
    }
}

/// A reply from 127.0.0.1 pointing at `location`.
func reply(_ location: String, usn: String = "uuid:renderer-1", from source: String = "127.0.0.1")
    -> SSDPDatagram
{
    SSDPDatagram(
        bytes: Array(
            ("HTTP/1.1 200 OK\r\nLOCATION: \(location)\r\n"
                + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: \(usn)\r\n\r\n").utf8),
        source: IPAddress(source)!)
}

/// A renderer on loopback: answers a GET with `description` and a POST with `soap`.
func renderer(description: @escaping @Sendable (UInt16) -> String, soap: String) async throws
    -> LoopbackServer
{
    try await LoopbackServer { connection in
        do {
            let head = String(
                decoding: try await connection.receive(through: Array("\r\n\r\n".utf8)),
                as: UTF8.self)
            if head.hasPrefix("POST") {
                let length =
                    head.split(separator: "\r\n").first { $0.hasPrefix("Content-Length: ") }
                    .flatMap { Int($0.dropFirst("Content-Length: ".count)) } ?? 0
                _ = try await connection.receive(count: length)
                try await connection.send(soap)
            } else {
                try await connection.send(description(0))
            }
            connection.close()
        } catch {
            Issue.record("the stand-in renderer failed: \(error)")
        }
    }
}

func ok(_ body: String) -> String {
    "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
}

private func discover(_ datagrams: [SSDPDatagram], timeout: Double = 2) async throws
    -> RendererDiscovery.Outcome
{
    try await RendererDiscovery.discover(
        transport: FakeSSDP(datagrams: datagrams), subnets: LocalSubnets([loopback]), seconds: 0.1,
        fetchTimeoutSeconds: timeout)
}

@Test func aRendererOnTheSubnetIsFoundWithItsFormats() async throws {
    let server = try await renderer(
        description: { _ in ok(descriptionXML(name: "AVR\u{9B}")) },
        soap: ok(sinkXML("http-get:*:audio/flac:*,http-get:*:audio/wav:*")))
    defer { server.stop() }
    let location = "http://127.0.0.1:\(server.port)/upnp/desc/aios_device/aios_device.xml"
    let outcome = try await discover([reply(location), reply(location)])
    #expect(outcome.problems == [])
    let found = try #require(outcome.renderers.first)
    #expect(outcome.renderers.count == 1)
    #expect(found.udn == "uuid:renderer-1")
    #expect(found.name == "AVR\\u{9B}")
    #expect(found.address == IPAddress("127.0.0.1"))
    #expect(found.sinkFormats.map(\.contentFormat) == ["audio/flac", "audio/wav"])
    #expect(found.formatsProblem == nil)
}

@Test func aControlURLOnAnotherHostIsNotFollowed() async throws {
    let other = try await renderer(description: { _ in ok("") }, soap: ok(sinkXML("x:y:z:w")))
    defer { other.stop() }
    let server = try await renderer(
        description: { _ in ok(descriptionXML(controlURL: "http://127.0.0.2:\(other.port)/ctl")) },
        soap: ok(sinkXML("")))
    defer { server.stop() }
    let outcome = try await discover([reply("http://127.0.0.1:\(server.port)/d.xml")])
    let found = try #require(outcome.renderers.first)
    #expect(found.sinkFormats == [])
    #expect(found.formatsProblem?.contains("leaves the host") == true)
    #expect(other.connectionCount == 0)
}

@Test func hostileDescriptionsAreReportedAndSkipped() async throws {
    let target = try await renderer(
        description: { _ in ok(descriptionXML()) }, soap: ok(sinkXML("")))
    defer { target.stop() }
    let descriptions: [(String, String)] = [
        (
            "HTTP/1.1 301 Moved\r\nLocation: http://127.0.0.1:\(target.port)/d.xml\r\n"
                + "Content-Length: 0\r\n\r\n", "the reply's status is 301"
        ),
        (
            "HTTP/1.1 200 OK\r\nContent-Length: \(2 * 1024 * 1024)\r\n\r\n",
            "the reply is over the 1048576-byte cap"
        ),
        (
            ok("<!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><root/>"),
            "it declares a DTD or entities"
        ),
        (
            ok(descriptionXML(renderer: "urn:x:device:Printer:1")),
            "it has no MediaRenderer with a UDN"
        ),
    ]
    for (description, why) in descriptions {
        let server = try await renderer(description: { _ in description }, soap: ok(sinkXML("")))
        defer { server.stop() }
        let location = try LocalURL("http://127.0.0.1:\(server.port)/d.xml", on: loopback)
        let outcome = try await discover([reply(location.description)])
        #expect(outcome.renderers == [])
        #expect(outcome.problems == [.description(location, why)])
    }
    #expect(target.connectionCount == 0)
}

@Test func aSilentRendererTimesOut() async throws {
    let silent = try await LoopbackServer { connection in
        _ = try? await connection.receive(seconds: 3) { _, closed in closed ? 0 : nil }
    }
    defer { silent.stop() }
    let location = try LocalURL("http://127.0.0.1:\(silent.port)/d.xml", on: loopback)
    let started = Date()
    let outcome = try await discover([reply(location.description)], timeout: 0.3)
    #expect(outcome.problems == [.description(location, "no answer in time")])
    #expect(Date().timeIntervalSince(started) < 2)
}

@Test func repliesFromOffTheSubnetAreNeverFetched() async throws {
    let server = try await renderer(
        description: { _ in ok(descriptionXML()) }, soap: ok(sinkXML("")))
    defer { server.stop() }
    let outcome = try await discover([
        reply("http://127.0.0.1:\(server.port)/d.xml", from: "192.168.1.20"),
        reply("http://192.168.1.20:\(server.port)/d.xml"),
    ])
    #expect(outcome.renderers == [])
    #expect(outcome.problems.count == 2)
    #expect(server.connectionCount == 0)
}
