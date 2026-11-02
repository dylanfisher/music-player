import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Receiver
@testable import UPnP

/// A made-up interface on 127/8, so stand-ins at 127.0.0.1 count as other devices.
private let loopback = NetworkInterface(
    name: "lo9", index: 1, address: IPAddress("127.0.0.2")!, prefixLength: 8)

private struct FakeSSDP: SSDPTransport {
    var datagrams: [SSDPDatagram]

    func search(_ request: [UInt8], from interfaces: [NetworkInterface], seconds: Double)
        async throws(LocalNetworkError) -> [SSDPDatagram]
    {
        datagrams
    }
}

private func reply(_ location: String, usn: String) -> SSDPDatagram {
    SSDPDatagram(
        bytes: Array(
            ("HTTP/1.1 200 OK\r\nLOCATION: \(location)\r\n"
                + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: \(usn)\r\n\r\n").utf8),
        source: IPAddress("127.0.0.1")!)
}

private func service(_ name: String) -> String {
    """
    <service><serviceType>urn:schemas-upnp-org:service:\(name):1</serviceType>
    <SCPDURL>/scpd/\(name).xml</SCPDURL><controlURL>/control/\(name)</controlURL></service>
    """
}

/// A Denon's description, with the three services whose descriptions are saved.
private let denonDescription = """
    <?xml version="1.0" encoding="utf-8"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>AVR</friendlyName><manufacturer>Denon</manufacturer>
    <modelName>Denon AVR-X1800H</modelName><UDN>uuid:avr</UDN>
    <serviceList>\(["AVTransport", "RenderingControl", "ConnectionManager"].map(service).joined())
    </serviceList></device></root>
    """

private let sink = "http-get:*:audio/flac:*"

/// A renderer on loopback that serves each path with its body and everything else with a 404.
private func server(_ bodies: [String: String]) async throws -> LoopbackServer {
    try await LoopbackServer { connection in
        do {
            let head = String(
                decoding: try await connection.receive(through: Array("\r\n\r\n".utf8)),
                as: UTF8.self)
            let parts = head.split(separator: " ")
            if head.hasPrefix("POST") {
                let length =
                    head.split(separator: "\r\n").first { $0.hasPrefix("Content-Length: ") }
                    .flatMap { Int($0.dropFirst("Content-Length: ".count)) } ?? 0
                _ = try await connection.receive(count: length)
            }
            if let body = bodies[String(parts[1])] {
                try await connection.send(
                    "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            } else {
                try await connection.send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            }
            connection.close()
        } catch {
            Issue.record("the stand-in renderer failed: \(error)")
        }
    }
}

/// A receiver on loopback that sends its status lines as soon as it's connected and keeps
/// what the app sends.
private final class StatusReceiver: @unchecked Sendable {
    let server: LoopbackServer
    private let lock = NSLock()
    private var heard = ""

    init(lines: String) async throws {
        let box = LockedText()
        server = try await LoopbackServer { connection in
            do {
                try await connection.send(lines)
                // The five queries, four bytes each.
                box.set(String(decoding: try await connection.receive(count: 20), as: UTF8.self))
            } catch {
                Issue.record("the stand-in receiver failed: \(error)")
            }
        }
        self.box = box
    }

    private let box: LockedText

    var received: String { box.text }
}

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func set(_ text: String) { lock.withLock { value = text } }

    var text: String { lock.withLock { value } }
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "capture-\(UUID().uuidString)", isDirectory: true)
}

private func read(_ name: String, in folder: URL) throws -> String {
    try String(
        contentsOf: folder.appendingPathComponent(name, isDirectory: false), encoding: .utf8)
}

@Test func theCaptureSavesWhatTheRendererAndTheReceiverSend() async throws {
    let doctype = "<!DOCTYPE root [<!ENTITY x \"y\">]><root/>"
    let renderer = try await server([
        "/desc.xml": denonDescription, "/bad.xml": doctype,
        "/scpd/AVTransport.xml": "<scpd>avt</scpd>",
        "/scpd/ConnectionManager.xml": "<scpd>cm</scpd>",
        "/control/ConnectionManager":
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>"
            + "<u:GetProtocolInfoResponse><Sink>\(sink)</Sink></u:GetProtocolInfoResponse>"
            + "</s:Body></s:Envelope>",
    ])
    defer { renderer.stop() }
    let receiver = try await StatusReceiver(lines: "PWON\rMV40\rMUOFF\rSIGAME\rMSDIRECT\r")
    defer { receiver.server.stop() }
    let base = "http://127.0.0.1:\(renderer.port)"
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let report = await NetworkCapture.run(
        folder: folder,
        transport: FakeSSDP(datagrams: [
            reply("\(base)/desc.xml", usn: "uuid:avr"),
            // The same device answering for another service is fetched once.
            reply("\(base)/desc.xml", usn: "uuid:avr::2"),
            reply("\(base)/bad.xml", usn: "uuid:bad"),
            SSDPDatagram(bytes: Array("junk".utf8), source: IPAddress("127.0.0.1")!),
        ]),
        interfaces: { [loopback] }, configured: nil, port: receiver.server.port,
        searchSeconds: 0.1, statusSeconds: 1)

    #expect(
        Set(report.written) == [
            "ssdp.txt", "1-description.xml", "1-protocolinfo.xml", "1-AVTransport-scpd.xml",
            "1-ConnectionManager-scpd.xml", "2-description.xml", "status-lines.txt",
        ])
    #expect(try read("1-description.xml", in: folder) == denonDescription)
    // Saved though discovery refuses it.
    #expect(try read("2-description.xml", in: folder) == doctype)
    #expect(try read("1-AVTransport-scpd.xml", in: folder) == "<scpd>avt</scpd>")
    #expect(try read("1-protocolinfo.xml", in: folder).contains(sink))
    let ssdp = try read("ssdp.txt", in: folder)
    #expect(ssdp.contains("LOCATION: \(base)/desc.xml") && ssdp.contains("junk"))
    let status = try read("status-lines.txt", in: folder)
    for line in ["PWON", "MV40", "MUOFF", "SIGAME", "MSDIRECT"] {
        #expect(status.contains("\t\(line)\n"), "\(status)")
    }
    // Only the five queries went out.
    #expect(receiver.received == "PW?\rMV?\rMU?\rSI?\rMS?\r")
    let failures = report.failures.joined(separator: "\n")
    #expect(failures.contains("1-RenderingControl-scpd.xml"), "\(failures)")
    #expect(failures.contains("bad.xml"), "\(failures)")
    #expect(report.capturedAnything)
}

@Test func theConfiguredAddressIsTheReceiverWhenNoDenonAnswers() async throws {
    let receiver = try await StatusReceiver(lines: "PWSTANDBY\r")
    defer { receiver.server.stop() }
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let report = await NetworkCapture.run(
        folder: folder, transport: FakeSSDP(datagrams: []), interfaces: { [loopback] },
        configured: IPAddress("127.0.0.1"), port: receiver.server.port, searchSeconds: 0.1,
        statusSeconds: 1)

    #expect(report.written == ["status-lines.txt"])
    #expect(try read("status-lines.txt", in: folder).contains("\tPWSTANDBY\n"))
    #expect(report.failures.contains { $0.contains("no device answered") })
}

@Test func aCaptureWithNothingInItSaysWhyAndWritesNothing() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let report = await NetworkCapture.run(
        folder: folder, transport: FakeSSDP(datagrams: []), interfaces: { [loopback] },
        configured: nil, port: LoopbackServer.refusingPort, searchSeconds: 0.1, statusSeconds: 1)

    #expect(!report.capturedAnything)
    #expect(report.failures.count == 2, "\(report.failures)")
    #expect(report.failures.contains { $0.contains("receiver.address isn't set") })
}

@Test func aReceiverThatRefusesIsReportedAndTheRestIsKept() async throws {
    let renderer = try await server(["/desc.xml": denonDescription])
    defer { renderer.stop() }
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let report = await NetworkCapture.run(
        folder: folder,
        transport: FakeSSDP(datagrams: [
            reply("http://127.0.0.1:\(renderer.port)/desc.xml", usn: "uuid:avr")
        ]),
        interfaces: { [loopback] }, configured: nil, port: LoopbackServer.refusingPort,
        searchSeconds: 0.1, statusSeconds: 1)

    #expect(report.written.contains("1-description.xml"))
    #expect(!report.written.contains("status-lines.txt"))
    #expect(report.failures.contains { $0.hasPrefix("status-lines.txt: it refused") })
}
