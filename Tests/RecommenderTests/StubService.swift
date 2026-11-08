import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Recommender
@testable import Settings

/// An interface whose subnet holds 127.0.0.1 as another device's address, so the client
/// reaches the stub on loopback.
let loopback = NetworkInterface(
    name: "lo9", index: 1, address: IPAddress("127.0.0.2")!, prefixLength: 8)

let testToken = ServiceToken("s3cret-token")

/// One request as the stub received it.
struct ReceivedRequest: Sendable {
    var head: String
    var body: [UInt8]

    var bodyText: String { String(decoding: body, as: UTF8.self) }
    var json: NSDictionary {
        (try? JSONSerialization.jsonObject(with: Data(body))) as? NSDictionary ?? [:]
    }
}

/// music-recommender on loopback: answers each request with the next of `replies`, recorded
/// as status and body, and keeps what it was sent.
final class StubService: @unchecked Sendable {
    let server: LoopbackServer
    private let lock = NSLock()
    private var queued: [(status: Int, body: String)]
    private var got: [ReceivedRequest] = []

    init(_ replies: [(status: Int, body: String)]) async throws {
        queued = replies
        let box = StubBox()
        server = try await LoopbackServer { connection in await box.stub?.serve(connection) }
        box.stub = self
    }

    var requests: [ReceivedRequest] { lock.withLock { got } }

    var client: RecommenderClient {
        get throws {
            try RecommenderClient(
                address: IPAddress("127.0.0.1")!, port: server.port, token: testToken,
                interfaces: [loopback])
        }
    }

    func stop() { server.stop() }

    private func serve(_ connection: LoopbackConnection) async {
        do {
            let head = String(
                decoding: try await connection.receive(through: Array("\r\n\r\n".utf8)),
                as: UTF8.self)
            let length =
                head.split(separator: "\r\n").first { $0.hasPrefix("Content-Length: ") }
                .flatMap { Int($0.dropFirst("Content-Length: ".count)) } ?? 0
            let body = try await connection.receive(count: length)
            let reply: (status: Int, body: String)? = lock.withLock {
                got.append(ReceivedRequest(head: head, body: body))
                return queued.isEmpty ? nil : queued.removeFirst()
            }
            guard let reply else {
                Issue.record("the stub has no reply left for \(head)")
                connection.close()
                return
            }
            let bytes = Array(reply.body.utf8)
            try await connection.send(
                "HTTP/1.1 \(reply.status) X\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n")
            // A client past its cap closes partway through, which fails the send; the test
            // checks what the client made of it.
            try? await connection.send(bytes)
            connection.close()
        } catch {
            Issue.record("the stub service failed: \(error)")
        }
    }
}

private final class StubBox: @unchecked Sendable {
    var stub: StubService?
}

/// A recorded reply from the fixtures folder.
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try String(contentsOf: url, encoding: .utf8)
}

/// The body of a refusal with `status`'s code, as the service sends it.
func failure(_ code: String, _ message: String = "no") -> String {
    #"{"ok": false, "error": {"code": "\#(code)", "message": "\#(message)"}}"#
}

/// The error `body` throws, or nil when it returns.
func caught<Value>(_ body: () async throws(RecommenderError) -> Value) async -> RecommenderError? {
    do throws(RecommenderError) {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}
