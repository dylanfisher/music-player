import Foundation
import Testing

@testable import Recommender

@Test func theRouteSendsTheSeedsKey() async throws {
    let stub = try await StubService([(200, try fixture("threads.json"))])
    defer { stub.stop() }
    _ = try await stub.client.threads(key: "a812")
    #expect(stub.requests.map(\.bodyText) == [#"{"key":"a812"}"#])
    #expect(stub.requests.first?.head.hasPrefix("POST /v1/threads HTTP/1.1\r\n") == true)
    #expect(
        stub.requests.first?.head.contains("\r\nAuthorization: Bearer s3cret-token\r\n") == true)
}

@Test func theContractsThreadsDecode() throws {
    let threads = try decodeReply(Array(try fixture("threads.json").utf8), as: AlbumThreads.self)
    #expect(threads.seed.key == "a812" && threads.seed.year == 1997)
    #expect(threads.seed.score == nil && threads.seed.reasons.isEmpty)
    #expect(threads.computedAt == 1_800_000_000)
    #expect(threads.albums.map(\.id) == ["r5150", "r6060"])
    #expect(threads.albums.allSatisfy { $0.score == nil && $0.reasons.isEmpty })
    #expect(threads.albums[1].community?.values?.have == 300 && threads.albums[1].year == nil)
    #expect(threads.threads.map(\.kind) == [.credit, .styles])
    #expect(threads.threads.map(\.ids) == [["r5150"], ["r6060"]], "a thread of one album")
    #expect(threads.threads[0].artist == RediscoverDay.Named(id: 21, name: "Dee Engineer"))
}

@Test func aThreadsReplyNotInTheContractFailsNamingTheField() throws {
    let text = try fixture("threads.json")
    let cases: [(String, String, String)] = [
        // An album of Threads has no score or reasons, the seed included.
        (#""plays": 0, "#, #""plays": 0, "score": 0.5, "#, "score"),
        (#""plays": 31, "#, #""plays": 31, "reasons": [], "#, "reasons"),
        (#""computed_at": 1800000000,"#, "", "computed_at"),
        (#""last_played": 1790000000,"#, #""last_played": 1790000000, "loved": 1,"#, "loved"),
        (#""label": null}]}"#, #""label": null, "role": null}]}"#, "role"),
        (#""kind": "styles""#, #""kind": "decade""#, "kind"),
        // A thread holds 1 album or more.
        (#""ids": ["r6060"]"#, #""ids": []"#, "ids"),
    ]
    for (from, to, field) in cases {
        let reply = text.replacingOccurrences(of: from, with: to)
        #expect(reply != text, "\(field)")
        do throws(RecommenderError.Kind) {
            _ = try decodeReply(Array(reply.utf8), as: AlbumThreads.self)
            Issue.record("\(field) decoded")
        } catch {
            guard case .unreadable(let why) = error else {
                Issue.record("\(field) gave \(error)")
                continue
            }
            #expect(why.contains(field), "\(why)")
        }
    }
}

@Test func theThreadsRefusalsAreTyped() throws {
    let codes: [(String, ServiceRefusal.Code)] = [
        ("no_profile", .noProfile), ("no_seed", .noSeed), ("untagged", .untagged),
        ("no_catalog", .noCatalog),
    ]
    for (text, code) in codes {
        #expect(throws: RecommenderError.Kind.refused(ServiceRefusal(code: code, message: "no"))) {
            try decodeReply(Array(failure(text).utf8), as: AlbumThreads.self)
        }
    }
}
