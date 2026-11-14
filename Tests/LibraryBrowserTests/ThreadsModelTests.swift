import Foundation
import Testing

@testable import LibraryBrowser
@testable import Recommender

/// An album of Threads, keyed `key`, as `rediscovered` makes one but unscored.
private func connected(_ key: String) -> RediscoverDay.Album {
    var album = rediscovered(key)
    album.score = nil
    album.reasons = []
    return album
}

/// Threads of the seed `seed`, a key, with the albums keyed `keys` and `threads`, each its
/// words and its albums' keys.
func albumThreads(
    _ seed: String, _ keys: [String], threads: [(String, [String])] = []
) -> AlbumThreads {
    AlbumThreads(
        seed: connected(seed), computedAt: 1_800_000_000, albums: keys.map(connected),
        threads: threads.map { words, keys in
            RediscoverDay.Thread(
                kind: .credit, words: words, ids: keys.map { "k\($0)" }, artist: nil, label: nil)
        })
}

/// What a stand-in service and library were asked, in order.
@MainActor
private final class ThreadsCalls {
    var calls: [String] = []
    /// What the service answers to each ask, in turn.
    var replies: [Result<AlbumThreads, RecommenderError>] = []
}

/// A model whose service answers `replies` in turn, and whose index has the albums `known` by
/// id, each titled as `rediscovered` titles it.
@MainActor
private func threadsModel(
    _ replies: [Result<AlbumThreads, RecommenderError>], known: Set<Int64>, calls: ThreadsCalls,
    profile: ProfileSender.Outcome = .unchanged
) -> ThreadsModel {
    let model = ThreadsModel(show: { albums in
        calls.calls.append("show \(albums.map(\.id))")
        return albums.filter { !known.contains($0.id) || $0.title != "Album a\($0.id)" }.map(\.id)
    })
    calls.replies = replies
    model.service = {
        ThreadsService(threads: { key throws(RecommenderError) in
            let reply = await MainActor.run {
                calls.calls.append("threads \(key)")
                return calls.replies.isEmpty ? nil : calls.replies.removeFirst()
            }
            guard let reply else { throw serviceError(.cancelled) }
            return try reply.get()
        })
    }
    model.sendProfile = { force in
        calls.calls.append(force ? "send profile, forced" : "send profile")
        return profile
    }
    return model
}

@MainActor
@Test func aReadSendsTheProfileAsksForTheSeedAndListsItsAlbumsInOrder() async {
    let calls = ThreadsCalls()
    let model = threadsModel(
        [.success(albumThreads("a2", ["a7", "a3"]))], known: [3, 7], calls: calls)
    var listed = 0
    model.listed = { listed += 1 }
    await model.read(2).value
    #expect(calls.calls == ["show []", "send profile", "threads a2", "show [7, 3]"])
    #expect(model.seed == 2 && model.albumIDs == [7, 3])
    #expect(model.problem == nil && !model.isReading)
    #expect(listed == 2, "emptied for the new seed, then listed")
}

@MainActor
@Test func aThreadsClickListsOnlyItsAlbumsAndAllListsThemAll() async {
    let calls = ThreadsCalls()
    let reply = albumThreads(
        "a2", ["a7", "a3", "a5"], threads: [("Engineer: Dee", ["a5", "a7"]), ("Label", ["a3"])])
    let model = threadsModel([.success(reply)], known: [3, 5, 7], calls: calls)
    await model.read(2).value
    calls.calls = []
    await model.choose(0)?.value
    #expect(model.chosen == 0 && model.albumIDs == [5, 7])
    #expect(calls.calls == ["show [5, 7]"])
    #expect(model.choose(0) == nil, "the thread chosen already")
    #expect(model.choose(9) == nil, "no such thread")
    await model.choose(nil)?.value
    #expect(model.chosen == nil && model.albumIDs == [7, 3, 5])
    model.selectedAlbumID = 7
    #expect(model.selectedThreads.map(\.words) == ["Engineer: Dee"])
}

@MainActor
@Test func anotherSeedClearsTheThreadsAtOnceAndARefreshKeepsThemUnderAnError() async {
    let calls = ThreadsCalls()
    let model = threadsModel(
        [
            .success(albumThreads("a2", ["a7"], threads: [("Label", ["a7"])])),
            .failure(serviceError(.unreachable(.refused("connection refused")))),
            .success(albumThreads("a7", ["a3"])),
        ], known: [3, 7], calls: calls)
    await model.read(2).value
    await model.choose(0)?.value
    await model.read(2).value
    #expect(model.reply?.seed.key == "a2", "the same seed's threads stay")
    #expect(model.chosen == 0)
    guard case .notAnswering = model.problem else {
        Issue.record("\(String(describing: model.problem))")
        return
    }
    let reading = model.read(7)
    #expect(model.reply == nil && model.chosen == nil && model.problem == nil)
    await reading.value
    #expect(model.albumIDs == [3])
}

@MainActor
@Test func aSeedTheServiceDoesntHaveSendsThisMacsProfileAndAsksOnceMore() async {
    let calls = ThreadsCalls()
    let noSeed = ServiceRefusal(code: .noSeed, message: "no album a2")
    let model = threadsModel(
        [.failure(serviceError(.refused(noSeed))), .success(albumThreads("a2", ["a7"]))],
        known: [7], calls: calls)
    await model.read(2).value
    #expect(
        calls.calls == [
            "show []", "send profile", "threads a2", "send profile, forced", "threads a2",
            "show [7]",
        ])
    #expect(model.problem == nil && model.albumIDs == [7])

    let still = threadsModel(
        [.failure(serviceError(.refused(noSeed))), .failure(serviceError(.refused(noSeed)))],
        known: [], calls: calls)
    await still.read(2).value
    #expect(still.problem == .refused(noSeed))
}

@MainActor
@Test func albumsStillUnknownAfterTheProfileWasSentAgainAreAnError() async {
    let calls = ThreadsCalls()
    let reply = albumThreads("a2", ["a7", "a99"])
    let model = threadsModel([.success(reply), .success(reply)], known: [7], calls: calls)
    await model.read(2).value
    #expect(
        calls.calls.filter { $0.hasPrefix("send") } == ["send profile", "send profile, forced"])
    #expect(model.problem == .unknownAlbums(1))
    #expect(model.albumIDs == [7], "the albums it has still list")
}

@MainActor
@Test func theThreadsErrorsAreRediscovers() async {
    let calls = ThreadsCalls()
    let untagged = ServiceRefusal(code: .untagged, message: "no release")
    let cases: [(RecommenderError, ThreadsModel.Problem)] = [
        (serviceError(.refused(untagged)), .refused(untagged)),
        (serviceError(.unauthorized), .tokenRefused("\(serviceError(.unauthorized))")),
        (serviceError(.offSubnet), .notAnswering("\(serviceError(.offSubnet))")),
    ]
    for (error, problem) in cases {
        let model = threadsModel([.failure(error)], known: [], calls: calls)
        await model.read(2).value
        #expect(model.problem == problem)
    }
    let unset = threadsModel([], known: [], calls: calls)
    unset.service = { nil }
    calls.calls = []
    await unset.read(2).value
    #expect(unset.problem == .notSet && calls.calls == ["show []"])
    let failing = threadsModel([], known: [], calls: calls, profile: .failed("didn't answer"))
    await failing.read(2).value
    #expect(failing.problem == .failed("didn't answer"))
}

/// Holds the first call that waits on it until `open()`.
@MainActor
private final class Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var held = false
    private var used = false

    func wait() async {
        guard !used else { return }
        used = true
        await withCheckedContinuation {
            waiting = $0
            held = true
        }
    }

    func open() {
        waiting?.resume()
        waiting = nil
    }
}

@MainActor
@Test func aReplyListedAfterAnotherSeedWasAskedForIsDropped() async throws {
    let calls = ThreadsCalls()
    let gate = Gate()
    let model = ThreadsModel(show: { albums in
        // The first seed's albums wait in the index while Back shows another seed.
        if !albums.isEmpty { await gate.wait() }
        return []
    })
    model.sendProfile = { _ in .unchanged }
    calls.replies = [
        .success(albumThreads("a2", ["a7"])), .success(albumThreads("a7", ["a3"])),
    ]
    model.service = threadsService(calls)
    let first = model.read(2)
    try await waitFor("the first seed's albums listing") { gate.held }
    await model.read(7).value
    #expect(model.reply?.seed.key == "a7")
    gate.open()
    await first.value
    #expect(model.reply?.seed.key == "a7", "the first seed's reply is dropped")
    #expect(model.seed == 7 && model.albumIDs == [3])
}

@MainActor
@Test func aSeedRetryAfterAnotherSeedWasAskedForAsksNothing() async throws {
    let calls = ThreadsCalls()
    let gate = Gate()
    let model = ThreadsModel(show: { _ in [] })
    model.sendProfile = { force in
        if force { await gate.wait() }
        return .unchanged
    }
    calls.replies = [
        .failure(serviceError(.refused(ServiceRefusal(code: .noSeed, message: "no")))),
        .success(albumThreads("a7", ["a3"])),
    ]
    model.service = threadsService(calls)
    let first = model.read(2)
    try await waitFor("the forced send") { gate.held }
    await model.read(7).value
    gate.open()
    await first.value
    #expect(calls.calls == ["threads a2", "threads a7"])
    #expect(model.reply?.seed.key == "a7")
}

/// A service that answers `calls.replies` in turn, recording each key asked.
@MainActor
private func threadsService(_ calls: ThreadsCalls) -> () -> ThreadsService? {
    {
        ThreadsService(threads: { key throws(RecommenderError) in
            let reply = await MainActor.run {
                calls.calls.append("threads \(key)")
                return calls.replies.isEmpty ? nil : calls.replies.removeFirst()
            }
            guard let reply else { throw serviceError(.cancelled) }
            return try reply.get()
        })
    }
}
