import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Recommender
@testable import Settings

/// The reply to a route that answers with a job.
private func jobReply() throws -> String { #"{"ok": true, "job": \#(try fixture("job.json"))}"# }

@Test func aCallPostsTheBearerTokenAndItsJSONBody() async throws {
    let stub = try await StubService([(200, try jobReply())])
    defer { stub.stop() }
    #expect(try await stub.client.cancel(42).id == 42)
    let request = try #require(stub.requests.first)
    #expect(request.head.hasPrefix("POST /v1/downloads/cancel HTTP/1.1\r\n"))
    #expect(request.head.contains("\r\nAuthorization: Bearer s3cret-token\r\n"))
    #expect(request.head.contains("\r\nContent-Type: application/json\r\n"))
    #expect(request.bodyText == #"{"id":42}"#)
}

@Test func a401IsUnauthorizedAndNamesTheAddressButNeverTheToken() async throws {
    let stub = try await StubService([(401, failure("unauthorized"))])
    defer { stub.stop() }
    let client = try stub.client
    let error = try #require(
        await caught { () async throws(RecommenderError) in try await client.cancel(42) })
    #expect(error.kind == .unauthorized)
    #expect(error.description.contains("127.0.0.1:\(stub.server.port)"))
    #expect(!error.description.contains(testToken.rawValue))
}

@Test func a400IsABadRequestWithItsCode() async throws {
    let stub = try await StubService([
        (400, failure("bad_request", "unknown field")), (400, failure("too_large")),
    ])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        await caught { () async throws(RecommenderError) in try await client.cancel(42) }?.kind
            == .badRequest(code: "bad_request", message: "unknown field"))
    #expect(
        await caught { () async throws(RecommenderError) in try await client.cancel(42) }?.kind
            == .badRequest(code: "too_large", message: "no"))
}

@Test func otherStatusesKeepTheirCode() async throws {
    let stub = try await StubService([(503, failure("busy")), (404, "not json")])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        await caught { () async throws(RecommenderError) in try await client.cancel(42) }?.kind
            == .status(503, code: "busy"))
    #expect(
        await caught { () async throws(RecommenderError) in try await client.cancel(42) }?.kind
            == .status(404, code: nil))
}

@Test func anOkFalseIsARefusalWithItsCode() async throws {
    let stub = try await StubService([(200, failure("downloads_off", "no [slskd] table"))])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        await caught { () async throws(RecommenderError) in try await client.cancel(42) }?.kind
            == .refused(ServiceRefusal(code: .downloadsOff, message: "no [slskd] table")))
}

@Test func repliesOfAnyOtherShapeAreUnreadable() async throws {
    let replies = [
        #"{"ok": true, "job": 1, "extra": 1}"#,
        #"{"ok": true}"#,
        #"{"ok": true, "job": 1}"#,
        #"{"job": 1}"#,
        #"{"ok": false, "error": {"code": "made_up", "message": "x"}}"#,
        #"{"ok": false, "error": {"code": "claimed", "message": "x", "other": 1}}"#,
        "[]",
    ]
    let stub = try await StubService(replies.map { (200, $0) })
    defer { stub.stop() }
    let client = try stub.client
    for reply in replies {
        let kind = await caught { () async throws(RecommenderError) in try await client.cancel(42)
        }?
        .kind
        guard case .unreadable = kind else {
            Issue.record("\(reply) gave \(String(describing: kind))")
            continue
        }
    }
}

@Test func aReplyOverTheCapIsRefused() async throws {
    let big =
        "{\"ok\": true, \"job\": \"\(String(repeating: "a", count: LocalHTTPClient.bodyCap))\"}"
    let stub = try await StubService([(200, big)])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        await caught { () async throws(RecommenderError) in try await client.cancel(42) }?.kind
            == .tooLarge(cap: LocalHTTPClient.bodyCap))
}

@Test func nothingListeningIsUnreachable() async throws {
    let client = try RecommenderClient(
        address: IPAddress("127.0.0.1")!, port: LoopbackServer.refusingPort, token: testToken,
        interfaces: [loopback])
    let error = try #require(
        await caught { () async throws(RecommenderError) in try await client.cancel(42) })
    guard case .unreachable = error.kind else {
        Issue.record("\(error)")
        return
    }
    #expect(error.description.contains("127.0.0.1:1"))
}

@Test func anAddressOffEverySubnetOrThisMacsOwnIsRefused() throws {
    for address in ["192.168.9.9", "127.0.0.2"] {
        #expect(throws: RecommenderError.self, "\(address)") {
            try RecommenderClient(
                address: IPAddress(address)!, port: 7878, token: testToken,
                interfaces: [loopback])
        }
    }
}
