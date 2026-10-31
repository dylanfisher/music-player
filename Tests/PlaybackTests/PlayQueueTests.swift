import Foundation
import Testing

@testable import Playback

private let urls = (0..<4).map { URL(fileURLWithPath: "/music/\($0).flac") }
private let reversed: @Sendable ([Int]) -> [Int] = { $0.reversed() }

@Test func repeatOffEndsAfterTheLastTrack() {
    var queue = PlayQueue()
    #expect(queue.replace(with: urls, first: 0, shuffled: reversed) == 0)
    #expect(queue.position(after: 2, natural: true) == 3)
    #expect(queue.position(after: 3, natural: true) == nil)
    #expect(queue.position(before: 0) == nil)
}

@Test func repeatOneRepeatsOnlyWhenTheTrackEndsByItself() {
    var queue = PlayQueue()
    _ = queue.replace(with: urls, first: 0, shuffled: reversed)
    queue.repeatMode = .one
    #expect(queue.position(after: 1, natural: true) == 1)
    #expect(queue.position(after: 1, natural: false) == 2)
    #expect(queue.position(after: 3, natural: false) == nil)
}

@Test func repeatAllWrapsBothWays() {
    var queue = PlayQueue()
    _ = queue.replace(with: urls, first: 0, shuffled: reversed)
    queue.repeatMode = .all
    #expect(queue.position(after: 3, natural: true) == 0)
    #expect(queue.position(before: 0) == 3)
}

@Test func shuffleStartsAtTheCurrentTrackAndUnshuffleReturnsToIt() {
    var queue = PlayQueue()
    _ = queue.replace(with: urls, first: 0, shuffled: reversed)
    #expect(queue.setShuffle(true, keeping: 2, shuffled: reversed) == 0)
    #expect(queue.order == [2, 3, 1, 0])
    #expect(queue.url(at: 1) == urls[3])

    #expect(queue.setShuffle(false, keeping: 2, shuffled: reversed) == 1)
    #expect(queue.order == [0, 1, 2, 3])
}

@Test func replacingWhileShuffledPutsTheFirstTrackFirst() {
    var queue = PlayQueue()
    _ = queue.setShuffle(true, keeping: nil, shuffled: reversed)
    #expect(queue.replace(with: urls, first: 1, shuffled: reversed) == 0)
    #expect(queue.order == [1, 3, 2, 0])
    #expect(queue.replace(with: [], first: 0, shuffled: reversed) == nil)
}

private func played(_ queue: PlayQueue) -> [URL] { queue.order.map { queue.entries[$0] } }

@Test func insertMoveAndRemoveEditThePlayOrder() {
    var queue = PlayQueue()
    _ = queue.replace(with: urls, first: 0, shuffled: reversed)
    let extra = URL(fileURLWithPath: "/music/extra.flac")
    #expect(queue.insert([extra], at: 2) == [0, 1, 3, 4])
    #expect(played(queue) == [urls[0], urls[1], extra, urls[2], urls[3]])
    #expect(queue.entries == played(queue))

    #expect(queue.move([0, 3], to: 5) == [3, 0, 1, 4, 2])
    #expect(played(queue) == [urls[1], extra, urls[3], urls[0], urls[2]])
    #expect(queue.move([4], to: 0) == [1, 2, 3, 4, 0])
    #expect(played(queue) == [urls[2], urls[1], extra, urls[3], urls[0]])

    #expect(queue.remove([1, 2]) == [0, nil, nil, 1, 2])
    #expect(played(queue) == [urls[2], urls[3], urls[0]])
    #expect(queue.entries == played(queue))
}

@Test func editsWhileShuffledKeepTheListedQueueApart() {
    var queue = PlayQueue()
    _ = queue.replace(with: urls, first: 0, shuffled: reversed)
    _ = queue.setShuffle(true, keeping: 0, shuffled: reversed)
    #expect(played(queue) == [urls[0], urls[3], urls[2], urls[1]])
    let extra = URL(fileURLWithPath: "/music/extra.flac")
    _ = queue.insert([extra], at: 1)
    #expect(played(queue) == [urls[0], extra, urls[3], urls[2], urls[1]])
    #expect(queue.entries == urls + [extra])
    _ = queue.remove([2])
    #expect(played(queue) == [urls[0], extra, urls[2], urls[1]])
    #expect(queue.entries == [urls[0], urls[1], urls[2], extra])
    // Shuffle off goes back to the listed order.
    _ = queue.setShuffle(false, keeping: 0, shuffled: reversed)
    #expect(played(queue) == [urls[0], urls[1], urls[2], extra])
}
