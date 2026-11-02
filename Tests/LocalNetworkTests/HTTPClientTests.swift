import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork

/// A stand-in device on loopback that reads one request and answers with `reply`.
private func device(_ reply: @escaping @Sendable (UInt16) -> String) async throws
    -> LoopbackServer
{
    try await LoopbackServer { connection in
        do {
            _ = try await connection.receive(through: Array("\r\n\r\n".utf8))
            try await connection.send(reply(0))
            connection.close()
        } catch {
            Issue.record("the stand-in device failed: \(error)")
        }
    }
}

private func url(_ server: LoopbackServer, _ path: String = "/desc.xml") throws -> LocalURL {
    try LocalURL("http://127.0.0.1:\(server.port)\(path)", on: loopback)
}

/// A GET's body as text, or its error.
private func get(
    _ url: LocalURL, cap: Int = LocalHTTPClient.bodyCap,
    timeoutSeconds: Double = LocalHTTPClient.timeoutSeconds
) async -> Result<String, LocalNetworkError> {
    do throws(LocalNetworkError) {
        let body = try await LocalHTTPClient.get(url, cap: cap, timeoutSeconds: timeoutSeconds)
        return .success(String(decoding: body, as: UTF8.self))
    } catch {
        return .failure(error)
    }
}

@Test func bodiesComeByLengthByChunksOrToTheClose() async throws {
    let replies = [
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello and more",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;x=y\r\nhel\r\n2\r\nlo\r\n0\r\nA: b\r\n\r\n",
        "HTTP/1.1 200 OK\r\n\r\nhello",
    ]
    for reply in replies {
        let server = try await device { _ in reply }
        defer { server.stop() }
        #expect(await get(try url(server)) == .success("hello"))
    }
}

@Test func aPostSendsItsFieldsAndBody() async throws {
    let request = LoopbackOnce<String>()
    let server = try await LoopbackServer { connection in
        do {
            let head = try await connection.receive(through: Array("\r\n\r\n".utf8))
            let body = try await connection.receive(count: 4)
            request.set(String(decoding: head + body, as: UTF8.self))
            try await connection.send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            connection.close()
        } catch {
            Issue.record("the stand-in device failed: \(error)")
        }
    }
    defer { server.stop() }
    let reply = try await LocalHTTPClient.post(
        try url(server, "/ctl?a=1"), fields: [("SOAPACTION", "\"x#y\"")], body: Array("<x/>".utf8))
    #expect(reply == Array("ok".utf8))
    #expect(
        try await request.value(seconds: 2)
            == "POST /ctl?a=1 HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nConnection: close\r\n"
            + "SOAPACTION: \"x#y\"\r\nContent-Length: 4\r\n\r\n<x/>")
}

@Test func aRedirectIsRefusedAndNotFollowed() async throws {
    let target = try await device { _ in "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx" }
    defer { target.stop() }
    let server = try await device { _ in
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/x\r\nContent-Length: 0\r\n\r\n"
    }
    defer { server.stop() }
    #expect(await get(try url(server)) == .failure(.status(302)))
    #expect(target.connectionCount == 0)
}

@Test func bodiesOverTheCapAreRefused() async throws {
    let big = String(repeating: "a", count: 101)
    let replies = [
        "HTTP/1.1 200 OK\r\nContent-Length: 101\r\n\r\n",
        "HTTP/1.1 200 OK\r\n\r\n\(big)",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n65\r\n\(big)\r\n0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(repeating: "1\r\na\r\n", count: 101) + "0\r\n\r\n",
    ]
    for reply in replies {
        let server = try await device { _ in reply }
        defer { server.stop() }
        #expect(
            await get(try url(server), cap: 100)
                == .failure(.tooLarge(cap: 100)))
    }
    let header =
        "HTTP/1.1 200 OK\r\nX: \(String(repeating: "a", count: LocalHTTPClient.headCap))\r\n\r\n"
    let server = try await device { _ in header }
    defer { server.stop() }
    #expect(await get(try url(server)) == .failure(.tooLarge(cap: LocalHTTPClient.headCap)))
}

@Test func malformedRepliesAreRefused() async throws {
    let replies: [(String, LocalNetworkError)] = [
        (
            "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort",
            .malformed("it ended before its Content-Length")
        ),
        (
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
            .malformed("its Content-Length is [\"1\", \"2\"]")
        ),
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nab",
            .malformed("its transfer encoding is [\"gzip\"]")
        ),
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
            .malformed("a chunk's size isn't hex")
        ),
        ("SSH-2.0-OpenSSH\r\n\r\n", .malformed("its first line isn't three parts")),
        ("HTTP/1.1 200 OK\r\nContent", .malformed("it ended inside its head")),
        ("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n", .status(500)),
    ]
    for (reply, error) in replies {
        let server = try await device { _ in reply }
        defer { server.stop() }
        #expect(await get(try url(server)) == .failure(error))
    }
}

@Test func aSilentDeviceTimesOutAndARefusedOneSaysSo() async throws {
    let silent = try await LoopbackServer { connection in
        _ = try? await connection.receive(seconds: 3) { _, closed in closed ? 0 : nil }
    }
    defer { silent.stop() }
    let started = Date()
    #expect(
        await get(try url(silent), timeoutSeconds: 0.3)
            == .failure(.timedOut))
    #expect(Date().timeIntervalSince(started) < 2)
    let port = LoopbackServer.refusingPort
    let refused = try LocalURL("http://127.0.0.1:\(port)/", on: loopback)
    let outcome = await get(refused)
    guard case .failure(.refused) = outcome else {
        Issue.record("a closed port wasn't reported as refused: \(outcome)")
        return
    }
}

@Test func aSignedOrOddChunkSizeIsRefusedNotTrusted() {
    for body in [
        "-1\r\nab\r\n0\r\n\r\n", "+2\r\nab\r\n0\r\n\r\n", " 2\r\nab\r\n0\r\n\r\n", "0x2\r\n",
    ] {
        #expect(
            decodeChunked(Array(body.utf8)[...], cap: 100)
                == .malformed("a chunk's size isn't hex"), "\(body)")
    }
    #expect(
        decodeChunked(Array("A\r\n0123456789\r\n0\r\n\r\n".utf8)[...], cap: 100)
            == .done(Array("0123456789".utf8)))
}

@Test func aCancelledFetchEndsAtOnce() async throws {
    let silent = try await LoopbackServer { connection in
        _ = try? await connection.receive(seconds: 3) { _, closed in closed ? 0 : nil }
    }
    defer { silent.stop() }
    let target = try url(silent)
    let started = Date()
    let fetch = Task { await get(target, timeoutSeconds: 5) }
    try await Task.sleep(nanoseconds: 100_000_000)
    fetch.cancel()
    #expect(await fetch.value == .failure(.cancelled))
    #expect(Date().timeIntervalSince(started) < 1)
}
