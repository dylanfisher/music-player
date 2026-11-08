import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Recommender
@testable import Settings

@Test func pingPostsTheBearerTokenAndReadsTheVersion() async throws {
    let stub = try await StubService([(200, try fixture("ping.json"))])
    defer { stub.stop() }
    #expect(try await stub.client.ping() == "0.1.0")
    let request = try #require(stub.requests.first)
    #expect(request.head.hasPrefix("POST /v1/ping HTTP/1.1\r\n"))
    #expect(request.head.contains("\r\nAuthorization: Bearer s3cret-token\r\n"))
    #expect(request.head.contains("\r\nContent-Type: application/json\r\n"))
    #expect(request.bodyText == "{}")
}

@Test func theConfigRouteDecodesAsTheContractShowsIt() async throws {
    let stub = try await StubService([(200, try fixture("config.json"))])
    defer { stub.stop() }
    let config = try await stub.client.downloadsConfig()
    #expect(
        config
            == DownloadsConfig(
                enabled: true, offReason: nil,
                formatPolicies: [.flac, .lossless, .mp3320, .any], defaultFormatPolicy: .flac,
                stagingDirName: "staging"))
    #expect(stub.requests.first?.head.hasPrefix("POST /v1/downloads/config ") == true)
}

@Test func a401IsUnauthorizedAndNamesTheAddressButNeverTheToken() async throws {
    let stub = try await StubService([(401, failure("unauthorized"))])
    defer { stub.stop() }
    let client = try stub.client
    let error = try #require(
        await caught { () async throws(RecommenderError) in try await client.ping() })
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
        await caught { () async throws(RecommenderError) in try await client.ping() }?.kind
            == .badRequest(code: "bad_request", message: "unknown field"))
    #expect(
        await caught { () async throws(RecommenderError) in try await client.ping() }?.kind
            == .badRequest(code: "too_large", message: "no"))
}

@Test func otherStatusesKeepTheirCode() async throws {
    let stub = try await StubService([(503, failure("busy")), (404, "not json")])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        await caught { () async throws(RecommenderError) in try await client.ping() }?.kind
            == .status(503, code: "busy"))
    #expect(
        await caught { () async throws(RecommenderError) in try await client.ping() }?.kind
            == .status(404, code: nil))
}

@Test func anOkFalseIsARefusalWithItsCode() async throws {
    let stub = try await StubService([(200, failure("downloads_off", "no [slskd] table"))])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        await caught { () async throws(RecommenderError) in try await client.ping() }?.kind
            == .refused(ServiceRefusal(code: .downloadsOff, message: "no [slskd] table")))
}

@Test func repliesOfAnyOtherShapeAreUnreadable() async throws {
    let replies = [
        #"{"ok": true, "version": "0.1.0", "extra": 1}"#,
        #"{"ok": true}"#,
        #"{"ok": true, "version": 1}"#,
        #"{"version": "0.1.0"}"#,
        #"{"ok": false, "error": {"code": "made_up", "message": "x"}}"#,
        #"{"ok": false, "error": {"code": "claimed", "message": "x", "other": 1}}"#,
        "[]",
    ]
    let stub = try await StubService(replies.map { (200, $0) })
    defer { stub.stop() }
    let client = try stub.client
    for reply in replies {
        let kind = await caught { () async throws(RecommenderError) in try await client.ping() }?
            .kind
        guard case .unreadable = kind else {
            Issue.record("\(reply) gave \(String(describing: kind))")
            continue
        }
    }
}

@Test func aReplyOverTheCapIsRefused() async throws {
    let big =
        "{\"ok\": true, \"version\": \"\(String(repeating: "a", count: LocalHTTPClient.bodyCap))\"}"
    let stub = try await StubService([(200, big)])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        await caught { () async throws(RecommenderError) in try await client.ping() }?.kind
            == .tooLarge(cap: LocalHTTPClient.bodyCap))
}

@Test func nothingListeningIsUnreachable() async throws {
    let client = try RecommenderClient(
        address: IPAddress("127.0.0.1")!, port: LoopbackServer.refusingPort, token: testToken,
        interfaces: [loopback])
    let error = try #require(
        await caught { () async throws(RecommenderError) in try await client.ping() })
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
