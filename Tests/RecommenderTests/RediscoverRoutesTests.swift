import Foundation
import Testing

@testable import Recommender

@Test func theRoutesSendTheDayAndTheAlbumsID() async throws {
    let stub = try await StubService([
        (200, try fixture("rediscover.json")), (200, try fixture("not-now.json")),
        (200, try fixture("not-now-undo.json")),
    ])
    defer { stub.stop() }
    let client = try stub.client
    _ = try await client.rediscover(day: "2026-11-12")
    #expect(try await client.notNow("r4242") == 1_802_592_000)
    #expect(try await client.undoNotNow("k3f9a0c1d"))
    #expect(
        stub.requests.map(\.bodyText) == [
            #"{"day":"2026-11-12"}"#, #"{"days":30,"id":"r4242"}"#, #"{"id":"k3f9a0c1d"}"#,
        ])
    #expect(
        stub.requests.map { $0.head.prefix(while: { $0 != "\r\n" }) } == [
            "POST /v1/rediscover HTTP/1.1", "POST /v1/rediscover/not_now HTTP/1.1",
            "POST /v1/rediscover/not_now/undo HTTP/1.1",
        ])
    for request in stub.requests {
        #expect(request.head.contains("\r\nAuthorization: Bearer s3cret-token\r\n"))
    }
}

@Test func theContractsDayDecodes() throws {
    let day = try decodeReply(Array(try fixture("rediscover.json").utf8), as: RediscoverDay.self)
    #expect(
        day.facts
            == RediscoverDay.Facts(
                day: "2026-11-12", computedAt: 1_800_000_000, albumsConsidered: 6541))
    #expect(day.albums.map(\.key) == ["a812", "a77"])
    let album = day.albums[0]
    #expect(album.id == "r4242" && album.releaseID == 4242 && album.year == 1997)
    #expect(album.label == RediscoverDay.Named(id: 30, name: "Seed Records"))
    #expect(album.lastPlayed == 1_693_000_000 && album.plays == 31 && album.skips == 2)
    #expect(album.community?.values?.have == 5120)
    #expect(album.reasons.map(\.kind) == [.notPlayedSince, .credit])
    #expect(album.reasons[1].keys == ["a90", "a133"])
    #expect(album.reasons[1].role == "Engineer")
    let untagged = day.albums[1]
    #expect(untagged.releaseID == nil && untagged.community == nil && untagged.lastPlayed == nil)
    #expect(untagged.reasons.map(\.kind) == [.neverPlayed])
    #expect(day.threads.map(\.kind) == [.label])
    #expect(day.threads[0].ids == ["r4242", "r5150"])
}

@Test func aKindTheContractDoesntHaveFailsTheReplyNamingTheField() throws {
    let text = try fixture("rediscover.json")
    let cases: [(String, String)] = [
        (#""kind": "never_played""#, #""kind": "forgotten""#),
        (#""kind": "label", "words""#, #""kind": "decade", "words""#),
    ]
    for (from, to) in cases {
        let reply = text.replacingOccurrences(of: from, with: to)
        #expect(reply != text)
        do throws(RecommenderError.Kind) {
            _ = try decodeReply(Array(reply.utf8), as: RediscoverDay.self)
            Issue.record("\(to) decoded")
        } catch {
            guard case .unreadable(let why) = error else {
                Issue.record("\(to) gave \(error)")
                continue
            }
            #expect(why.contains("kind"), "\(why)")
        }
    }
}

@Test func aRediscoverReplyNotInTheContractFailsNamingTheField() throws {
    let text = try fixture("rediscover.json")
    let cases: [(String, any Decodable.Type, String)] = [
        (text.replacingOccurrences(of: #""score": 0.61, "#, with: ""), RediscoverDay.self, "score"),
        (
            text.replacingOccurrences(of: #""plays": 0,"#, with: #""plays": 0, "loved": 1,"#),
            RediscoverDay.self, "loved"
        ),
        (#"{"ok": true}"#, NotNowReply.self, "until"),
        (#"{"ok": true, "removed": true, "until": 1}"#, UndoNotNowReply.self, "until"),
    ]
    for (reply, type, field) in cases {
        do throws(RecommenderError.Kind) {
            _ = try decodeReply(Array(reply.utf8), as: type)
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

@Test func noProfileIsARefusal() throws {
    #expect(throws: RecommenderError.Kind.refused(ServiceRefusal(code: .noProfile, message: "no")))
    {
        try decodeReply(Array(failure("no_profile").utf8), as: RediscoverDay.self)
    }
}

@Test func theDayIsTheLocalGregorianDate() throws {
    let date = Date(timeIntervalSince1970: 1_794_452_400)  // 2026-11-12 03:00 UTC
    #expect(
        RediscoverDay.day(of: date, in: try #require(TimeZone(identifier: "UTC"))) == "2026-11-12")
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    #expect(RediscoverDay.day(of: date, in: losAngeles) == "2026-11-11")
}
