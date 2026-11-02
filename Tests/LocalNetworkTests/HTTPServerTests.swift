import Darwin
import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork

/// A server on loopback serving files from a temporary folder by name, recording which keys it
/// was asked to resolve.
private final class Fixture: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var resolved: [String] = []
    private var heard: [String] = []
    var server: HTTPServer<String>!
    private var clock = 1_000_000.0

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "http-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data((0..<200).map { UInt8($0) }).write(to: folder.appendingPathComponent("track"))
        try Data().write(to: folder.appendingPathComponent("empty"))
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("link").path,
            withDestinationPath: folder.appendingPathComponent("track").path)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("folder"), withIntermediateDirectories: false)
    }

    deinit {
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func start(
        accepts: (@Sendable (IPAddress) -> Bool)? = nil, idleSeconds: Double = 30,
        headSeconds: Double = 10
    ) async throws {
        server = try await HTTPServer<String>.start(
            on: loopback, accepts: accepts ?? loopback.holds,
            resolve: { [self] key in
                lock.withLock { resolved.append(key) }
                guard key != "gone" else { return nil }
                return HTTPServedFile(
                    path: folder.appendingPathComponent(key).path, contentType: "audio/flac")
            },
            problem: { [self] message in lock.withLock { heard.append(message) } },
            idleSeconds: idleSeconds, headSeconds: headSeconds,
            now: { [self] in lock.withLock { clock } })
    }

    var resolvedKeys: [String] { lock.withLock { resolved } }
    var problems: [String] { lock.withLock { heard } }
    func advance(_ seconds: Double) { lock.withLock { clock += seconds } }

    var host: String { "127.0.0.1:\(server.port)" }

    /// The path part of the URL serving `key`.
    func target(_ key: String) -> String {
        String(server.url(for: key).dropFirst("http://\(host)".count))
    }

    /// Sends `request` and returns the whole reply, up to the server's close.
    func exchange(_ request: String) async throws -> (status: Int, head: String, body: [UInt8]) {
        let connection = try await LoopbackConnection.connect(port: server.port)
        defer { connection.close() }
        try await connection.send(request)
        let reply = try await connection.receiveAll()
        let end = try #require(reply.firstRange(of: Array("\r\n\r\n".utf8)))
        let head = String(decoding: reply[..<end.lowerBound], as: UTF8.self)
        let status = try #require(Int(head.split(separator: " ")[1]))
        return (status, head, Array(reply[end.upperBound...]))
    }

    func get(_ target: String, _ fields: String = "", method: String = "GET") async throws
        -> (status: Int, head: String, body: [UInt8])
    {
        try await exchange("\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\n\(fields)\r\n")
    }
}

@Test func aTrackIsServedWholeOrByOneRange() async throws {
    let fixture = try Fixture()
    try await fixture.start()
    let target = fixture.target("track")
    let whole = try await fixture.get(target)
    #expect(whole.status == 200)
    #expect(whole.body == (0..<200).map { UInt8($0) })
    #expect(whole.head.contains("Content-Type: audio/flac"))
    #expect(whole.head.contains("Content-Length: 200"))
    #expect(whole.head.contains("Accept-Ranges: bytes"))
    let head = try await fixture.get(target, method: "HEAD")
    #expect(head.status == 200)
    #expect(head.body == [])
    #expect(head.head.contains("Content-Length: 200"))
    let ranges: [(String, ClosedRange<Int>)] = [
        ("bytes=10-19", 10...19), ("bytes=190-", 190...199), ("bytes=-5", 195...199),
        ("bytes=150-500", 150...199), ("bytes=-500", 0...199),
    ]
    for (range, bytes) in ranges {
        let part = try await fixture.get(target, "Range: \(range)\r\n")
        #expect(part.status == 206, "\(range)")
        #expect(part.body == bytes.map { UInt8($0) }, "\(range)")
        #expect(
            part.head.contains("Content-Range: bytes \(bytes.lowerBound)-\(bytes.upperBound)/200"))
    }
    let empty = try await fixture.get(fixture.target("empty"))
    #expect(empty.status == 200)
    #expect(empty.body == [])
}

@Test func aRangeOutsideTheFileOrMoreThanOneIsRefused() async throws {
    let fixture = try Fixture()
    try await fixture.start()
    let target = fixture.target("track")
    for fields in [
        "Range: bytes=200-\r\n", "Range: bytes=0-1,5-6\r\n",
        "Range: bytes=0-1\r\nRange: bytes=2-3\r\n",
        "Range: bytes=5-2\r\n", "Range: items=0-1\r\n", "Range: bytes=-0\r\n", "Range: bytes=-\r\n",
        "Range: bytes=x-1\r\n",
    ] {
        let reply = try await fixture.get(target, fields)
        #expect(reply.status == 416, "\(fields)")
        #expect(reply.body == [])
    }
    #expect(
        try await fixture.get(target, "Range: bytes=200-\r\n").head.contains(
            "Content-Range: bytes */200"))
}

@Test func anythingButAToken404sWithoutTouchingTheFileSystem() async throws {
    let fixture = try Fixture()
    try await fixture.start()
    _ = fixture.target("track")
    for target in [
        "/", "/track", "/../../etc/passwd", "/" + String(repeating: "0", count: 32),
        "/" + String(repeating: "A", count: 32), "/" + String(repeating: "0", count: 33),
        "http://evil/x", "*",
    ] {
        #expect(try await fixture.get(target).status == 404, "\(target)")
    }
    #expect(fixture.resolvedKeys == [])
    // A token the index no longer holds, a link, a folder: 404, and the file isn't sent.
    for key in ["gone", "link", "folder"] {
        #expect(try await fixture.get(fixture.target(key)).status == 404, "\(key)")
    }
    #expect(fixture.resolvedKeys == ["gone", "link", "folder"])
}

@Test func tokensAreRandomPerKeyAndExpireAfterADay() async throws {
    let fixture = try Fixture()
    try await fixture.start()
    let first = fixture.target("track")
    #expect(first.count == 33)
    #expect(fixture.target("track") == first)
    #expect(fixture.target("empty") != first)
    fixture.advance(HTTPServer<String>.tokenLifetimeSeconds - 1)
    #expect(try await fixture.get(first).status == 200)
    fixture.advance(1)
    #expect(try await fixture.get(first).status == 404)
    let renewed = fixture.target("track")
    #expect(renewed != first)
    #expect(try await fixture.get(renewed).status == 200)
}

@Test func onlyGETAndHEADToTheBoundHostWithNoBodyAreAnswered() async throws {
    let fixture = try Fixture()
    try await fixture.start()
    let target = fixture.target("track")
    let host = fixture.host
    let refused: [(String, Int)] = [
        ("POST \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n", 405),
        ("PUT \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n", 405),
        ("OPTIONS * HTTP/1.1\r\nHost: \(host)\r\n\r\n", 405),
        // DNS rebinding: the page's own name, or a missing Host.
        ("GET \(target) HTTP/1.1\r\nHost: evil.example:\(fixture.server.port)\r\n\r\n", 400),
        ("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", 400),
        ("GET \(target) HTTP/1.1\r\n\r\n", 400),
        ("GET \(target) HTTP/1.1\r\nHost: \(host)\r\nHost: \(host)\r\n\r\n", 400),
        ("GET \(target) HTTP/1.1\r\nHost: \(host)\r\nContent-Length: 3\r\n\r\nabc", 400),
        ("GET \(target) HTTP/1.1\r\nHost: \(host)\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
        ("GET \(target) HTTP/2.0\r\nHost: \(host)\r\n\r\n", 400),
        ("GET \(target)\r\n\r\n", 400),
        (
            "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nX: \(String(repeating: "a", count: 8200))\r\n\r\n",
            431
        ),
    ]
    for (request, status) in refused {
        #expect(try await fixture.exchange(request).status == status, "\(request.prefix(60))")
    }
    #expect(fixture.resolvedKeys == [])
}

@Test func connectionsPastEightAreRefusedAndIdleOnesClosed() async throws {
    let fixture = try Fixture()
    try await fixture.start(idleSeconds: 0.5)
    var open: [LoopbackConnection] = []
    for _ in 0..<HTTPServer<String>.connectionCap {
        open.append(try await LoopbackConnection.connect(port: fixture.server.port))
    }
    try await waitFor { fixture.server.openConnections == HTTPServer<String>.connectionCap }
    let ninth = try await LoopbackConnection.connect(port: fixture.server.port)
    #expect(await ninth.closes(within: 1))
    #expect(fixture.problems.contains { $0.contains("8 are open") })
    // Idle ones close on their own.
    for connection in open { #expect(await connection.closes(within: 2)) }
    try await waitFor { fixture.server.openConnections == 0 }
    #expect(try await fixture.get(fixture.target("track")).status == 200)
}

@Test func aConnectionFromOffTheSubnetIsRefused() async throws {
    let fixture = try Fixture()
    try await fixture.start(accepts: { _ in false })
    let connection = try await LoopbackConnection.connect(port: fixture.server.port)
    try await connection.send(
        "GET \(fixture.target("track")) HTTP/1.1\r\nHost: \(fixture.host)\r\n\r\n")
    #expect(try await connection.receiveAll() == [])
    #expect(fixture.problems.contains { $0.contains("refused a connection from 127.0.0.1") })
    #expect(fixture.resolvedKeys == [])
}

@Test func itListensOnItsOneAddressAndStops() async throws {
    let fixture = try Fixture()
    try await fixture.start()
    let port = fixture.server.port
    #expect(port != 0)
    // Bound to 127.0.0.1 alone, so ::1 on the same port finds nothing.
    #expect(await refuses(host: "::1", port: port))
    let held = try await LoopbackConnection.connect(port: port)
    try await waitFor { fixture.server.openConnections == 1 }
    fixture.server.stop()
    #expect(await held.closes(within: 2))
    #expect(await refuses(host: "127.0.0.1", port: port))
}

/// Whether a TCP connection to `host` and `port` fails.
private func refuses(host: String, port: UInt16) async -> Bool {
    let address = IPAddress(host)!
    let interface = NetworkInterface(
        name: "lo0", index: 1, address: address, prefixLength: address.bytes.count * 8)
    guard let url = try? LocalURL("http://\(address.urlHost):\(port)/", on: interface) else {
        Issue.record("no URL for \(host)")
        return false
    }
    do throws(LocalNetworkError) {
        _ = try await LocalHTTPClient.get(url, timeoutSeconds: 1)
        return false
    } catch {
        return error != .timedOut
    }
}

/// Waits up to two seconds for `condition`.
func waitFor(_ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("the condition never held")
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Test func aHeadTricklingInIsCutOffAtItsDeadline() async throws {
    let fixture = try Fixture()
    try await fixture.start(headSeconds: 0.5)
    let connection = try await LoopbackConnection.connect(port: fixture.server.port)
    defer { connection.close() }
    let started = Date()
    // A byte every 100 ms keeps the idle timer from ever firing.
    for byte in "GET /aaaaaaaaaaaaaaaaaa".utf8 {
        guard !(await connection.closes(within: 0.1)) else { break }
        try? await connection.send([byte])
    }
    #expect(await connection.closes(within: 1))
    #expect(Date().timeIntervalSince(started) < 1.5)
}
