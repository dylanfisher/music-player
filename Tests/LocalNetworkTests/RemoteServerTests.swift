import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork

/// A remote server on loopback whose handler echoes each request, or opens an event stream for
/// `/events`, recording the streams it stopped.
private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = 0
    private var losses = 0
    private var heard: [String] = []
    private var continuations: [AsyncStream<[UInt8]>.Continuation] = []
    var server: RemoteServer!

    deinit { server?.stop() }

    func start(headSeconds: Double = 10, idleSeconds: Double = 30) async throws {
        server = try await RemoteServer.start(
            on: [loopback], port: 0, hostNames: ["studio.local"],
            allowsOrigin: { $0 == "http://other.local:47800" },
            handler: { [self] request in
                if request.path == "/events" {
                    let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
                    lock.withLock { continuations.append(continuation) }
                    continuation.yield(Array("data: first\n\n".utf8))
                    return .events(stream, stop: { [self] in lock.withLock { stopped += 1 } })
                }
                if request.path == "/unchanged" {
                    return .reply(RemoteReply(.notModified, fields: [("ETag", "\"1\"")]))
                }
                let text =
                    "\(request.method) \(request.path) \(request.query ?? "-") "
                    + String(decoding: request.body, as: UTF8.self)
                let size = request.path == "/big" ? 4000 : 0
                return .reply(
                    RemoteReply(
                        .ok, contentType: "text/plain",
                        body: Array((text + String(repeating: "x", count: size)).utf8)))
            },
            problem: { [self] message in lock.withLock { heard.append(message) } },
            lost: { [self] in lock.withLock { losses += 1 } }, headSeconds: headSeconds,
            idleSeconds: idleSeconds)
    }

    var stoppedStreams: Int { lock.withLock { stopped } }
    var problems: [String] { lock.withLock { heard } }
    var lostListeners: Int { lock.withLock { losses } }
    var streams: [AsyncStream<[UInt8]>.Continuation] { lock.withLock { continuations } }
    var host: String { "127.0.0.1:\(server.port)" }

    func connect() async throws -> LoopbackConnection {
        try await LoopbackConnection.connect(port: server.port)
    }

    /// Sends `request` and reads one reply with a `Content-Length`, leaving the connection open.
    func exchange(_ request: String, on connection: LoopbackConnection) async throws
        -> (status: Int, head: String, body: [UInt8])
    {
        try await connection.send(request)
        let headBytes = try await connection.receive(through: Array("\r\n\r\n".utf8))
        let head = String(decoding: headBytes, as: UTF8.self)
        let status = try #require(Int(head.split(separator: " ")[1]))
        let length =
            head.split(separator: "\r\n").first { $0.hasPrefix("Content-Length: ") }
            .flatMap { Int($0.dropFirst("Content-Length: ".count)) } ?? 0
        let body = length == 0 ? [] : try await connection.receive(count: length)
        return (status, head, body)
    }

    func exchange(_ request: String) async throws -> (status: Int, head: String, body: [UInt8]) {
        let connection = try await connect()
        defer { connection.close() }
        return try await exchange(request, on: connection)
    }

    func get(_ target: String, _ fields: String = "") async throws
        -> (status: Int, head: String, body: [UInt8])
    {
        try await exchange("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\(fields)\r\n")
    }
}

@Test func requestsAreHandedOnWithTheirBodiesOverOneKeptAliveConnection() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let connection = try await fixture.connect()
    defer { connection.close() }
    let posted = try await fixture.exchange(
        "POST /api/command?x=1 HTTP/1.1\r\nHost: \(fixture.host)\r\nContent-Length: 5\r\n\r\nhello",
        on: connection)
    #expect(posted.status == 200)
    #expect(String(decoding: posted.body, as: UTF8.self) == "POST /api/command x=1 hello")
    #expect(posted.head.contains("Connection: keep-alive"))
    let got = try await fixture.exchange(
        "GET /api/state HTTP/1.1\r\nHost: studio.local:\(fixture.server.port)\r\n\r\n",
        on: connection)
    #expect(String(decoding: got.body, as: UTF8.self) == "GET /api/state - ")
    let closing = try await fixture.exchange(
        "GET / HTTP/1.1\r\nHost: \(fixture.host)\r\nConnection: close\r\n\r\n", on: connection)
    #expect(closing.head.contains("Connection: close"))
    #expect(await connection.closes(within: 2))
}

@Test func aHostThatIsntTheServersOwnIsRefused() async throws {
    let fixture = Fixture()
    try await fixture.start()
    for host in ["evil.example:\(fixture.server.port)", "127.0.0.1", "studio.local:1"] {
        let reply = try await fixture.exchange("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
        #expect(reply.status == 400, "\(host)")
        #expect(reply.body.isEmpty)
    }
    let none = try await fixture.exchange("GET / HTTP/1.1\r\n\r\n")
    #expect(none.status == 400)
}

@Test func headsBodiesAndMethodsPastTheRulesAreRefused() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let host = "Host: \(fixture.host)\r\n"
    let long = try await fixture.exchange(
        "GET / HTTP/1.1\r\n\(host)X: \(String(repeating: "a", count: 9000))\r\n\r\n")
    #expect(long.status == 431)
    let refusals: [(String, Int)] = [
        ("POST / HTTP/1.1\r\n\(host)Content-Length: 16385\r\n\r\n", 413),
        ("POST / HTTP/1.1\r\n\(host)Transfer-Encoding: chunked\r\n\r\n", 400),
        ("GET / HTTP/1.1\r\n\(host)Content-Length: 2\r\n\r\nab", 400),
        ("POST / HTTP/1.1\r\n\(host)Content-Length: 1\r\nContent-Length: 1\r\n\r\na", 400),
        ("POST / HTTP/1.1\r\n\(host)Content-Length: +1\r\n\r\na", 400),
        ("DELETE / HTTP/1.1\r\n\(host)\r\n", 405),
        ("GET / HTTP/2.0\r\n\(host)\r\n", 400),
        ("GET nothing HTTP/1.1\r\n\(host)\r\n", 400),
    ]
    for (request, status) in refusals {
        #expect(try await fixture.exchange(request).status == status, "\(request)")
    }
    let fullBody = String(repeating: "b", count: 16384)
    let full = try await fixture.exchange(
        "POST / HTTP/1.1\r\n\(host)Content-Length: 16384\r\n\r\n\(fullBody)")
    #expect(full.status == 200)
}

@Test func aHeadOrBodyThatTricklesPastItsTimeIsClosed() async throws {
    let fixture = Fixture()
    try await fixture.start(headSeconds: 0.3)
    let slow = try await fixture.connect()
    defer { slow.close() }
    try await slow.send("POST / HTTP/1.1\r\nHost: \(fixture.host)\r\nContent-Length: 4\r\n\r\nab")
    #expect(await slow.closes(within: 3))
    let silent = try await fixture.connect()
    defer { silent.close() }
    #expect(await silent.closes(within: 3))
}

@Test func aKeptAliveConnectionClosesWhenIdle() async throws {
    let fixture = Fixture()
    try await fixture.start(idleSeconds: 0.3)
    let connection = try await fixture.connect()
    defer { connection.close() }
    _ = try await fixture.exchange(
        "GET / HTTP/1.1\r\nHost: \(fixture.host)\r\n\r\n", on: connection)
    #expect(await connection.closes(within: 3))
}

@Test func connectionsPastTheCapAreClosedAtOnce() async throws {
    let fixture = Fixture()
    try await fixture.start()
    var open: [LoopbackConnection] = []
    defer { for connection in open { connection.close() } }
    for _ in 0..<RemoteServer.connectionCap { open.append(try await fixture.connect()) }
    try await waitFor { fixture.server.openConnections.all == RemoteServer.connectionCap }
    let extra = try await fixture.connect()
    defer { extra.close() }
    #expect(await extra.closes(within: 3))
    #expect(fixture.server.openConnections.all == RemoteServer.connectionCap)
}

@Test func corsEchoesOnlyAnAllowedOriginAndAnswersItsPreflight() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let other = "http://other.local:47800"
    let allowed = try await fixture.get("/api/state", "Origin: \(other)\r\n")
    #expect(allowed.status == 200)
    #expect(allowed.head.contains("Access-Control-Allow-Origin: \(other)"))
    #expect(allowed.head.contains("Access-Control-Expose-Headers: ETag"))
    let own = try await fixture.get("/api/state", "Origin: http://\(fixture.host)\r\n")
    #expect(own.status == 200)
    for origin in ["http://evil.example", "null", "http://other.local:47801"] {
        let refused = try await fixture.get("/api/state", "Origin: \(origin)\r\n")
        #expect(refused.status == 403, "\(origin)")
        #expect(!refused.head.contains("Access-Control"))
    }
    let preflight = try await fixture.exchange(
        "OPTIONS /api/command HTTP/1.1\r\nHost: \(fixture.host)\r\nOrigin: \(other)\r\n"
            + "Access-Control-Request-Headers: authorization\r\n\r\n")
    #expect(preflight.status == 204)
    #expect(preflight.head.contains("Access-Control-Allow-Origin: \(other)"))
    #expect(
        preflight.head.contains(
            "Access-Control-Allow-Headers: Authorization, Content-Type, If-None-Match"))
    #expect(!preflight.head.contains("Content-Length"))
    let foreign = try await fixture.exchange(
        "OPTIONS /api/command HTTP/1.1\r\nHost: \(fixture.host)\r\nOrigin: http://evil.example"
            + "\r\n\r\n")
    #expect(foreign.status == 403)
    let bare = try await fixture.exchange(
        "OPTIONS /api/command HTTP/1.1\r\nHost: \(fixture.host)\r\n\r\n")
    #expect(bare.status == 403)
}

@Test func aNotModifiedReplyHasNoBodyAndKeepsTheConnection() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let connection = try await fixture.connect()
    defer { connection.close() }
    let unchanged = try await fixture.exchange(
        "GET /unchanged HTTP/1.1\r\nHost: \(fixture.host)\r\n\r\n", on: connection)
    #expect(unchanged.status == 304)
    #expect(unchanged.head.contains("HTTP/1.1 304 Not Modified"))
    #expect(!unchanged.head.contains("Content-Length"))
    let next = try await fixture.exchange(
        "GET /small HTTP/1.1\r\nHost: \(fixture.host)\r\n\r\n", on: connection)
    #expect(next.status == 200)
}

@Test func aLargeReplyIsGzippedWhenTheClientTakesGzip() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let plain = try await fixture.get("/big")
    #expect(!plain.head.contains("Content-Encoding"))
    let zipped = try await fixture.get("/big", "Accept-Encoding: br, gzip;q=0.8\r\n")
    #expect(zipped.head.contains("Content-Encoding: gzip"))
    #expect(zipped.body.count < plain.body.count)
    // A gzip member is a 10-byte header, raw deflate, and an 8-byte trailer.
    #expect(zipped.body.prefix(2) == [0x1F, 0x8B])
    let deflated = Data(zipped.body.dropFirst(10).dropLast(8))
    let inflated = try (deflated as NSData).decompressed(using: .zlib) as Data
    #expect(Array(inflated) == plain.body)
    let refused = try await fixture.get("/big", "Accept-Encoding: gzip;q=0\r\n")
    #expect(!refused.head.contains("Content-Encoding"))
    let small = try await fixture.get("/small", "Accept-Encoding: gzip\r\n")
    #expect(!small.head.contains("Content-Encoding"))
}

@Test func anEventStreamSendsEachEventAndIsStoppedWhenItsConnectionCloses() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let connection = try await fixture.connect()
    try await connection.send("GET /events HTTP/1.1\r\nHost: \(fixture.host)\r\n\r\n")
    let head = String(
        decoding: try await connection.receive(through: Array("\r\n\r\n".utf8)), as: UTF8.self)
    #expect(head.hasPrefix("HTTP/1.1 200"))
    #expect(head.contains("Content-Type: text/event-stream"))
    #expect(!head.contains("Content-Length"))
    #expect(
        try await connection.receive(through: Array("\n\n".utf8)) == Array("data: first\n\n".utf8))
    try await waitFor { fixture.streams.count == 1 }
    fixture.streams[0].yield(Array("data: second\n\n".utf8))
    #expect(
        try await connection.receive(through: Array("\n\n".utf8)) == Array("data: second\n\n".utf8))
    #expect(fixture.server.openConnections.streams == 1)
    connection.close()
    try await waitFor { fixture.stoppedStreams == 1 && fixture.server.openConnections.all == 0 }
}

@Test func streamsPastTheirCapAreRefusedAndStopIsCalledForEach() async throws {
    let fixture = Fixture()
    try await fixture.start()
    var open: [LoopbackConnection] = []
    defer { for connection in open { connection.close() } }
    for _ in 0..<RemoteServer.eventStreamCap {
        let connection = try await fixture.connect()
        try await connection.send("GET /events HTTP/1.1\r\nHost: \(fixture.host)\r\n\r\n")
        _ = try await connection.receive(through: Array("data: first\n\n".utf8))
        open.append(connection)
    }
    let refused = try await fixture.get("/events", "Origin: http://other.local:47800\r\n")
    #expect(refused.status == 503)
    #expect(refused.head.contains("Access-Control-Allow-Origin: http://other.local:47800"))
    #expect(refused.head.contains("Vary: Origin"))
    try await waitFor { fixture.stoppedStreams == 1 }
    fixture.server.stop()
    try await waitFor { fixture.stoppedStreams == RemoteServer.eventStreamCap + 1 }
    #expect(fixture.server.openConnections.all == 0)
}

@Test func aStreamThatEndsClosesItsConnection() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let connection = try await fixture.connect()
    defer { connection.close() }
    try await connection.send("GET /events HTTP/1.1\r\nHost: \(fixture.host)\r\n\r\n")
    _ = try await connection.receive(through: Array("data: first\n\n".utf8))
    try await waitFor { fixture.streams.count == 1 }
    fixture.streams[0].finish()
    #expect(await connection.closes(within: 3))
}

@Test func theRulesAnswerFromTheBytesAlone() {
    let host = "Host: 10.0.0.2:47800\r\n"
    func status(_ request: String) -> Int? {
        answer(
            toRemoteRequest: Array(request.utf8), authority: "10.0.0.2:47800",
            allowedOrigin: "http://10.0.0.3:47800")?.status
    }
    #expect(status("GET / HTTP/1.1\r\n\(host)\r\n") == 200)
    #expect(status("POST / HTTP/1.1\r\n\(host)Content-Length: 3\r\n\r\nab") == nil)
    #expect(status("POST / HTTP/1.1\r\n\(host)Content-Length: 3\r\n\r\nabc") == 200)
    #expect(status("GET / HTTP/1.1\r\n\(host)Origin: http://10.0.0.3:47800\r\n\r\n") == 200)
    #expect(status("GET / HTTP/1.1\r\n\(host)Origin: http://10.0.0.2:47800\r\n\r\n") == 200)
    #expect(status("GET / HTTP/1.1\r\n\(host)Origin: http://10.0.0.4:47800\r\n\r\n") == 403)
    #expect(
        status("GET / HTTP/1.1\r\n\(host)Origin: a\r\nOrigin: http://10.0.0.3:47800\r\n\r\n")
            == 403)
    #expect(status("OPTIONS / HTTP/1.1\r\n\(host)Origin: http://10.0.0.3:47800\r\n\r\n") == 204)
    #expect(status("GET / HTTP/1.1\r\nHost: 10.0.0.2\r\n\r\n") == 400)
}

@Test func everyReplySaysItVariesByOriginWithOrWithoutOne() async throws {
    let fixture = Fixture()
    try await fixture.start()
    #expect(try await fixture.get("/api/state").head.contains("Vary: Origin"))
    let other = try await fixture.get("/api/state", "Origin: http://other.local:47800\r\n")
    #expect(other.head.contains("Vary: Origin"))
}

@Test func refusedConnectionsPastTheLogCapAreCountedInOneLineAtTheStop() async throws {
    let fixture = Fixture()
    try await fixture.start()
    var open: [LoopbackConnection] = []
    defer { for connection in open { connection.close() } }
    for _ in 0..<RemoteServer.connectionCap { open.append(try await fixture.connect()) }
    try await waitFor { fixture.server.openConnections.all == RemoteServer.connectionCap }
    let extra = RemoteServer.refusalLogCap + 5
    for _ in 0..<extra {
        let refused = try await fixture.connect()
        #expect(await refused.closes(within: 3))
        refused.close()
    }
    let logged = fixture.problems.filter { $0.contains("connections are open") }
    #expect(logged.count == RemoteServer.refusalLogCap)
    fixture.server.stop()
    #expect(fixture.problems.last == "the web remote refused 5 more connections")
}

@Test func aListenerThatFailsAfterItWasReadyIsDroppedSaidAndReported() async throws {
    let fixture = Fixture()
    try await fixture.start()
    fixture.server.loseFirstListener()
    #expect(fixture.lostListeners == 1)
    #expect(fixture.problems.contains { $0.hasPrefix("the web remote stopped listening on lo0") })
}
