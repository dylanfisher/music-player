import Foundation
import Testing

@testable import Recommender

/// An album of a profile, named `title`, played `plays` times.
private func profile(_ titles: [String], plays: Int = 0) -> LibraryProfile {
    LibraryProfile(
        albums: titles.enumerated().map { place, title in
            LibraryProfile.Album(
                key: "a\(place + 1)", artist: "Made-Up Artist", title: title, durations: [200],
                catalogNumbers: [], barcodes: [], discogsReleaseID: nil, plays: plays, loved: 0,
                lastPlayed: nil, skips: 0)
        })
}

/// What the stand-in answers for a profile of `albums` albums.
private func receipt(_ albums: Int) -> ProfileReceipt {
    ProfileReceipt(albums: albums, withReleaseID: 0, queued: 0)
}

/// A stand-in for the library and the service: the profile read now, and each send, which
/// waits until the test lets it answer when `holding` is set.
@MainActor
private final class Stand {
    var library = profile(["A"])
    var sent: [LibraryProfile] = []
    var holding = false
    var failing = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var sender: ProfileSender {
        ProfileSender(
            read: { [self] in library },
            send: {
                { [self] profile throws(RecommenderError) in
                    sent.append(profile)
                    if holding { await withCheckedContinuation { held.append($0) } }
                    if failing {
                        throw RecommenderError(
                            service: "http://192.168.1.20:7878/v1/profile",
                            kind: .unreachable(.refused("connection refused")))
                    }
                    return receipt(profile.albums.count)
                }
            })
    }

    /// Lets the sends waiting answer.
    func release() {
        let waiting = held
        held = []
        for send in waiting { send.resume() }
    }

    /// Lets the main actor run the tasks it has queued, until a send waits or all are done.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
@Test func nothingIsSentWhileTheServiceIsntSet() async {
    let sender = ProfileSender(read: { profile(["A"]) }, send: { nil })
    #expect(await sender.send().value == .notSet)
}

@MainActor
@Test func theProfileIsSentFirstThenOnlyOnceItChanged() async {
    let stand = Stand()
    let sender = stand.sender
    #expect(await sender.send().value == .sent(receipt(1)))
    #expect(await sender.send().value == .unchanged)
    stand.library = profile(["A"], plays: 1)
    #expect(await sender.send().value == .sent(receipt(1)))
    #expect(stand.sent == [profile(["A"]), profile(["A"], plays: 1)])
}

@MainActor
@Test func aForcedSendGoesThoughNothingChanged() async {
    let stand = Stand()
    let sender = stand.sender
    _ = await sender.send().value
    #expect(await sender.send(force: true).value == .sent(receipt(1)))
    #expect(stand.sent.count == 2)
}

@MainActor
@Test func asksWhileASendIsOutAreBatchedIntoOneMoreSend() async {
    let stand = Stand()
    stand.holding = true
    let sender = stand.sender
    let first = sender.send()
    await stand.settle()
    #expect(stand.sent.count == 1)
    // A scan, then Rediscover opening, while the first send is out: one send after it.
    stand.library = profile(["A", "B"])
    let second = sender.send()
    let third = sender.send(force: true)
    await stand.settle()
    #expect(stand.sent.count == 1, "one send at a time")
    stand.release()
    #expect(await first.value == .sent(receipt(1)))
    await stand.settle()
    #expect(stand.sent.count == 2)
    stand.release()
    #expect(await second.value == .sent(receipt(2)))
    #expect(await third.value == .sent(receipt(2)))
    #expect(stand.sent == [profile(["A"]), profile(["A", "B"])])
}

@MainActor
@Test func aFailedSendIsTriedAgainAtTheNextAskAndNamesTheAddress() async {
    let stand = Stand()
    stand.failing = true
    let sender = stand.sender
    guard case .failed(let why) = await sender.send().value else {
        Issue.record("the send didn't fail")
        return
    }
    #expect(why.contains("192.168.1.20:7878"))
    stand.failing = false
    #expect(await sender.send().value == .sent(receipt(1)))
    #expect(stand.sent.count == 2)
}
