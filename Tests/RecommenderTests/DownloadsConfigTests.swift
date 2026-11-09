import Foundation
import Testing

@testable import LocalNetwork
@testable import Recommender

private func config(slskd: String?) -> String {
    let url = slskd.map { "\"\($0)\"" } ?? "null"
    return
        #"{"ok": true, "enabled": true, "off_reason": null, "format_policies": ["flac", "lossless", "mp3_320", "any"], "default_format_policy": "flac", "staging_dir_name": "staging", "slskd_url": \#(url)}"#
}

private func page(_ slskd: String?, reachedAt service: String) throws -> String? {
    let reply = try decodeReply(Array(config(slskd: slskd).utf8), as: DownloadsConfig.self)
    return reply.slskdPage(reachedAt: try #require(IPAddress(service)))?.absoluteString
}

@Test func aLoopbackSlskdIsOpenedAtTheServicesAddressWithItsSchemeAndPort() throws {
    #expect(
        try page("http://127.0.0.1:5030", reachedAt: "192.168.1.20") == "http://192.168.1.20:5030")
    #expect(
        try page("https://localhost:5031/", reachedAt: "192.168.1.20")
            == "https://192.168.1.20:5031/")
    #expect(try page("http://[::1]:5030", reachedAt: "192.168.1.20") == "http://192.168.1.20:5030")
    #expect(try page("http://127.0.0.1:5030", reachedAt: "fe80::1") == "http://[fe80::1]:5030")
}

@Test func anotherHostIsOpenedAsTheServiceReportsIt() throws {
    #expect(
        try page("http://192.168.1.30:5030", reachedAt: "192.168.1.20")
            == "http://192.168.1.30:5030")
}

@Test func noSlskdOrOneThatIsntAWebPageOpensNothing() throws {
    #expect(try page(nil, reachedAt: "192.168.1.20") == nil)
    #expect(try page("ftp://127.0.0.1:5030", reachedAt: "192.168.1.20") == nil)
    #expect(try page("not a url", reachedAt: "192.168.1.20") == nil)
}

@Test func theConfigRouteIsAskedWithAnEmptyBody() async throws {
    let stub = try await StubService([(200, config(slskd: "http://127.0.0.1:5030"))])
    defer { stub.stop() }
    let opened = try await stub.client.slskdPage()
    #expect(opened?.absoluteString == "http://127.0.0.1:5030")
    let request = try #require(stub.requests.first)
    #expect(request.head.hasPrefix("POST /v1/downloads/config "))
    #expect(request.bodyText == "{}")
}

@Test func aConfigReplyWithAFieldMissingIsUnreadable() {
    let text = config(slskd: nil).replacingOccurrences(of: #", "slskd_url": null"#, with: "")
    #expect(throws: (any Error).self) {
        try decodeReply(Array(text.utf8), as: DownloadsConfig.self)
    }
}
