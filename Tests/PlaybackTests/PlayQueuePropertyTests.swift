import Foundation
import Testing

@testable import Fixtures
@testable import Playback

/// The queue as a test would write it: the listed tracks and the play order, as URLs. Every URL
/// in a case is distinct, so a URL names one entry.
private struct QueueModel {
    var listed: [URL] = []
    var played: [URL] = []
    var shuffle = false
    /// The tracks inserted, which the user queued, as opposed to those a replace listed.
    var queued: Set<URL> = []
}

/// Random edits against the model: what plays at each position, where each old position went,
/// and the listed order the queue unshuffles to.
@Test func randomQueueEditsMatchAReferenceModel() throws {
    try forEachPropertyCase("queue edits") { random in
        var queue = PlayQueue()
        var model = QueueModel()
        var next = 0
        func newURLs(_ count: Int) -> [URL] {
            defer { next += count }
            return (next..<next + count).map { URL(fileURLWithPath: "/music/\($0).flac") }
        }
        // A seeded shuffle the queue and the model both apply to the same list.
        var shuffleSeed = random.next()
        func shuffled(_ items: [Int]) -> [Int] {
            var generator = SplitMix64(seed: shuffleSeed)
            return items.shuffled(using: &generator)
        }
        func randomPositions() -> IndexSet {
            IndexSet(model.played.indices.filter { _ in random.chance(0.3) })
        }
        for step in 0..<Int.random(in: 1...30, using: &random) {
            shuffleSeed = random.next()
            let before = model.played
            var moved: [Int?]?
            switch Int.random(in: 0..<7, using: &random) {
            case 0:
                let urls = newURLs(Int.random(in: 0...6, using: &random))
                let first = urls.isEmpty ? 0 : Int.random(in: 0..<urls.count, using: &random)
                let position = queue.replace(with: urls, first: first, shuffled: shuffled)
                model.listed = urls
                model.queued = []
                if urls.isEmpty {
                    model.played = []
                    try #require(position == nil)
                } else if model.shuffle {
                    let rest = shuffled(urls.indices.filter { $0 != first }).map { urls[$0] }
                    model.played = [urls[first]] + rest
                    try #require(position == 0)
                } else {
                    model.played = urls
                    try #require(position == first)
                }
            case 1:
                let on = random.chance(0.5)
                let keeping =
                    model.played.isEmpty || random.chance(0.2)
                    ? nil : Int.random(in: 0..<model.played.count, using: &random)
                let position = queue.setShuffle(on, keeping: keeping, shuffled: shuffled)
                model.shuffle = on
                if let keeping {
                    let kept = model.played[keeping]
                    if on {
                        let others = model.listed.indices.filter { model.listed[$0] != kept }
                        model.played = [kept] + shuffled(others).map { model.listed[$0] }
                    } else {
                        model.played = model.listed
                    }
                    try #require(position.map { model.played[$0] } == kept, "step \(step)")
                } else {
                    model.played =
                        on
                        ? shuffled(Array(model.listed.indices)).map { model.listed[$0] }
                        : model.listed
                    try #require(position == nil)
                }
            case 2, 3:
                let urls = newURLs(Int.random(in: 0...3, using: &random))
                let at = Int.random(in: 0...model.played.count, using: &random)
                moved = queue.insert(urls, at: at)
                model.played.insert(contentsOf: urls, at: at)
                model.queued.formUnion(urls)
                if model.shuffle { model.listed += urls } else { model.listed = model.played }
            case 4, 5:
                let positions = randomPositions()
                let destination = Int.random(in: 0...model.played.count, using: &random)
                moved = queue.move(positions, to: destination)
                let moving = positions.map { model.played[$0] }
                let split = destination - positions.filter { $0 < destination }.count
                var staying = model.played.indices.filter { !positions.contains($0) }
                    .map { model.played[$0] }
                staying.insert(contentsOf: moving, at: split)
                model.played = staying
                if !model.shuffle { model.listed = model.played }
            default:
                let positions = randomPositions()
                moved = queue.remove(positions)
                let removed = Set(positions.map { model.played[$0] })
                model.played.removeAll { removed.contains($0) }
                model.listed.removeAll { removed.contains($0) }
            }
            let played = queue.order.indices.map { queue.url(at: $0) }
            try #require(played == model.played, "step \(step): play order")
            try #require(queue.entries == model.listed, "step \(step): listed order")
            try #require(queue.order.sorted() == Array(queue.entries.indices), "step \(step)")
            try checkQueued(queue, model, position: Int.random(in: 0..<1000, using: &random))
            if let moved {
                try #require(moved.count == before.count)
                for (old, new) in moved.enumerated() {
                    let expected = model.played.firstIndex(of: before[old])
                    try #require(new == expected, "step \(step): old position \(old)")
                }
            }
            let count = model.played.count
            for mode in RepeatMode.allCases where count > 0 {
                queue.repeatMode = mode
                let position = Int.random(in: 0..<count, using: &random)
                let after = position + 1 < count ? position + 1 : (mode == .all ? 0 : nil)
                try #require(queue.position(after: position, natural: false) == after)
                try #require(
                    queue.position(after: position, natural: true)
                        == (mode == .one ? position : after))
                let before = position > 0 ? position - 1 : (mode == .all ? count - 1 : nil)
                try #require(queue.position(before: position) == before)
            }
            queue.repeatMode = .off
        }
    }
}

/// Which entries the queue has as queued by the user, and where an add after `position`, taken
/// modulo the queue's length, would go.
private func checkQueued(_ queue: PlayQueue, _ model: QueueModel, position: Int) throws {
    try #require(queue.queued == queue.entries.map { model.queued.contains($0) })
    guard !model.played.isEmpty else { return }
    let position = position % model.played.count
    let end =
        model.played[(position + 1)...].firstIndex { !model.queued.contains($0) }
        ?? model.played.count
    try #require(queue.endOfQueued(after: position) == end)
}
