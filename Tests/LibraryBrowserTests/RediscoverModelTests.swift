import Foundation
import Testing

@testable import LibraryBrowser
@testable import Recommender

/// An album of a day, keyed `key`, titled after it.
func rediscovered(_ key: String, id: String? = nil) -> RediscoverDay.Album {
    RediscoverDay.Album(
        id: id ?? "k\(key)", key: key, artist: "Made-Up Artist", title: "Album \(key)",
        releaseID: nil, year: nil, label: nil, styles: [], plays: 0, skips: 0, lastPlayed: nil,
        score: 0.5, community: nil,
        reasons: [
            RediscoverDay.Reason(
                kind: .neverPlayed, words: "Never played", keys: [], artist: nil, role: nil,
                label: nil)
        ])
}

/// A day of the albums keyed `keys`, best first.
func rediscoverDay(_ keys: [String], day: String = "2026-11-12") -> RediscoverDay {
    RediscoverDay(
        facts: RediscoverDay.Facts(day: day, computedAt: 1_800_000_000, albumsConsidered: 6541),
        albums: keys.map { rediscovered($0) }, threads: [])
}

/// What a stand-in service and library were asked, in order.
@MainActor
final class RediscoverCalls {
    var calls: [String] = []
    /// What the service answers to each ask for a day, in turn.
    var replies: [Result<RediscoverDay, RecommenderError>] = []
    /// Whether Not Now's marks fail.
    var marksFail = false
    /// The service's ids of the albums marked Not Now.
    var marked: Set<String> = []
}

/// The error a stand-in service throws for `kind`, at the address the panel names.
func serviceError(_ kind: RecommenderError.Kind) -> RecommenderError {
    RecommenderError(service: "http://192.168.1.20:7878/v1/rediscover", kind: kind)
}

/// A model whose service answers `replies` in turn, whose index has the albums `known` by id,
/// each titled as `rediscovered` titles it, and whose clock is noon UTC on 2026-11-12.
@MainActor
func rediscoverModel(
    _ replies: [Result<RediscoverDay, RecommenderError>], known: Set<Int64>,
    calls: RediscoverCalls, profile: ProfileSender.Outcome = .unchanged
) -> RediscoverModel {
    let model = RediscoverModel(
        show: { albums in
            calls.calls.append("show \(albums.map(\.id))")
            return albums.filter { !known.contains($0.id) || $0.title != "Album a\($0.id)" }
                .map(\.id)
        },
        now: { Date(timeIntervalSince1970: 1_794_484_800) },
        timeZone: { TimeZone(identifier: "UTC")! })
    calls.replies = replies
    model.service = {
        RediscoverService(
            day: { day throws(RecommenderError) in
                let reply = await MainActor.run {
                    calls.calls.append("day \(day)")
                    return calls.replies.isEmpty ? nil : calls.replies.removeFirst()
                }
                guard let reply else { throw serviceError(.cancelled) }
                return try reply.get()
            },
            notNow: { id throws(RecommenderError) in
                let fails = await MainActor.run {
                    calls.calls.append("not now \(id)")
                    return calls.marksFail
                }
                if fails { throw serviceError(.unreachable(.refused("connection refused"))) }
                return 1_802_592_000
            },
            undoNotNow: { id throws(RecommenderError) in
                await MainActor.run { calls.calls.append("undo \(id)") }
                return true
            })
    }
    model.sendProfile = { force in
        calls.calls.append(force ? "send profile, forced" : "send profile")
        return profile
    }
    return model
}

@MainActor
@Test func aReadSendsTheProfileThenListsTodaysAlbumsTheIndexHasInOrder() async {
    let calls = RediscoverCalls()
    let model = rediscoverModel(
        [.success(rediscoverDay(["a7", "a3"]))], known: [3, 7], calls: calls)
    var listed = 0
    model.listed = { listed += 1 }
    await model.read().value
    #expect(calls.calls == ["send profile", "day 2026-11-12", "show [7, 3]"])
    #expect(model.albumIDs == [7, 3])
    #expect(model.problem == nil && !model.isReading)
    #expect(listed == 1)
    model.selectedAlbumID = 3
    #expect(model.selected?.title == "Album a3")
}

@MainActor
@Test func anUnknownKeySendsThisMacsProfileAndAsksOnceMore() async {
    let calls = RediscoverCalls()
    let model = rediscoverModel(
        [.success(rediscoverDay(["a7", "a99"])), .success(rediscoverDay(["a7", "a3"]))],
        known: [3, 7], calls: calls)
    await model.read().value
    #expect(
        calls.calls == [
            "send profile", "day 2026-11-12", "show [7, 99]", "send profile, forced",
            "day 2026-11-12", "show [7, 3]",
        ])
    #expect(model.albumIDs == [7, 3])
    #expect(model.problem == nil)
}

@MainActor
@Test func keysStillUnknownAfterTheProfileWasSentAgainAreAnError() async {
    let calls = RediscoverCalls()
    // A key of another Mac's, a key this player doesn't write, and one whose album here has
    // another title.
    let day = rediscoverDay(["a7", "a99", "r12"])
    var renamed = rediscoverDay(["a3"])
    renamed.albums[0].title = "Another Album"
    let model = rediscoverModel(
        [
            .success(day),
            .success(
                RediscoverDay(facts: day.facts, albums: day.albums + renamed.albums, threads: [])),
        ],
        known: [3, 7], calls: calls)
    await model.read().value
    #expect(
        calls.calls.filter { $0.hasPrefix("send") } == ["send profile", "send profile, forced"])
    #expect(model.problem == .unknownAlbums(3))
    #expect(model.albumIDs == [7], "the albums it has still list")
}

@MainActor
@Test func withoutTheServiceSetNothingIsAsked() async {
    let calls = RediscoverCalls()
    let model = rediscoverModel([], known: [], calls: calls)
    model.service = { nil }
    await model.read().value
    #expect(calls.calls.isEmpty)
    #expect(model.problem == .notSet)
}

@MainActor
@Test func aRefusalAndAFailedProfileSendAreProblems() async {
    let calls = RediscoverCalls()
    let refusal = ServiceRefusal(code: .noProfile, message: "no profile")
    let model = rediscoverModel(
        [.failure(serviceError(.refused(refusal)))], known: [], calls: calls)
    await model.read().value
    #expect(model.problem == .refused(refusal))

    let failing = rediscoverModel(
        [], known: [], calls: calls,
        profile: .failed("music-recommender at 192.168.1.20 didn't answer"))
    await failing.read().value
    #expect(failing.problem == .failed("music-recommender at 192.168.1.20 didn't answer"))
}

@MainActor
@Test func theDayIsTheClocksInItsTimeZone() async {
    let calls = RediscoverCalls()
    let model = rediscoverModel([.success(rediscoverDay([]))], known: [], calls: calls)
    let model2 = RediscoverModel(
        show: { _ in [] }, now: { Date(timeIntervalSince1970: 1_794_484_800) },
        timeZone: { TimeZone(identifier: "Pacific/Kiritimati")! })
    model2.service = model.service
    model2.sendProfile = { _ in .unchanged }
    await model2.read().value
    #expect(calls.calls == ["day 2026-11-13"])
}

@MainActor
@Test func notNowTakesTheAlbumOutAtOnceMarksItAndReadsTheDayAgain() async {
    let calls = RediscoverCalls()
    let model = rediscoverModel(
        [
            .success(rediscoverDay(["a7", "a3", "a5"])),
            .success(rediscoverDay(["a7", "a5", "a9"])),
        ],
        known: [3, 5, 7, 9], calls: calls)
    await model.read().value
    calls.calls = []
    var listedThen: [[Int64]] = []
    model.listed = { listedThen.append(model.albumIDs) }
    // An album not among the day's is ignored.
    let marked = await model.notNow([3, 42])?.value
    #expect(marked == ["ka3"])
    #expect(listedThen.first == [7, 5], "out of the list before the service answers")
    #expect(
        calls.calls == [
            "show [7, 5]", "not now ka3", "send profile", "day 2026-11-12", "show [7, 5, 9]",
        ])
    #expect(model.albumIDs == [7, 5, 9])
    #expect(model.notNow([42]) == nil, "nothing of the day's")

    calls.calls = []
    calls.replies = [.success(rediscoverDay(["a7", "a3", "a5"]))]
    await model.undoNotNow(["ka3"])?.value
    #expect(calls.calls == ["undo ka3", "send profile", "day 2026-11-12", "show [7, 3, 5]"])
    #expect(model.albumIDs == [7, 3, 5])
}

@MainActor
@Test func aNotNowThatFailsIsSaidAndTheReadPutsTheAlbumBack() async {
    let calls = RediscoverCalls()
    let day = rediscoverDay(["a7", "a3"])
    let model = rediscoverModel([.success(day), .success(day)], known: [3, 7], calls: calls)
    await model.read().value
    calls.marksFail = true
    let marked = await model.notNow([3])?.value
    #expect(marked == [])
    #expect(model.albumIDs == [7, 3])
    #expect(model.notice?.contains("couldn't mark Album a3 Not Now") == true)
    #expect(model.notice?.contains("192.168.1.20:7878") == true)
    calls.replies = [.success(day)]
    await model.read().value
    #expect(model.notice == nil, "a Refresh drops it")
}
