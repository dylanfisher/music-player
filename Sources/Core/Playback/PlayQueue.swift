import Foundation

/// The tracks to play and the order to play them in. Positions count through `order`, which is
/// the queue as listed, or shuffled.
struct PlayQueue {
    private(set) var entries: [URL] = []
    /// Indices into `entries`, in play order.
    private(set) var order: [Int] = []
    private(set) var shuffle = false
    var repeatMode = RepeatMode.off

    /// Replaces the queue. `first` is an index into `entries` and becomes position 0 when
    /// shuffling. Returns its position, or nil for an empty queue.
    mutating func replace(
        with entries: [URL], first: Int, shuffled: ([Int]) -> [Int]
    ) -> Int? {
        self.entries = entries
        guard !entries.isEmpty else {
            order = []
            return nil
        }
        precondition(entries.indices.contains(first), "index \(first) is outside the queue")
        return reorder(keeping: first, shuffled: shuffled)
    }

    /// Turns shuffle on or off, keeping the entry at `position` where it is in the new order: at
    /// the start of a shuffle, or at its own index without one. Returns its new position.
    mutating func setShuffle(_ on: Bool, keeping position: Int?, shuffled: ([Int]) -> [Int])
        -> Int?
    {
        shuffle = on
        guard let position else {
            order = on ? shuffled(Array(entries.indices)) : Array(entries.indices)
            return nil
        }
        return reorder(keeping: order[position], shuffled: shuffled)
    }

    private mutating func reorder(keeping entry: Int, shuffled: ([Int]) -> [Int]) -> Int {
        guard shuffle else {
            order = Array(entries.indices)
            return entry
        }
        order = [entry] + shuffled(entries.indices.filter { $0 != entry })
        return 0
    }

    func entry(at position: Int) -> Int { order[position] }

    func url(at position: Int) -> URL { entries[order[position]] }

    /// What plays after `position`. When the track ends by itself (`natural`), repeat one plays it
    /// again; skipping moves on. Repeat all wraps to the start; otherwise the end gives nil.
    func position(after position: Int, natural: Bool) -> Int? {
        if natural && repeatMode == .one { return position }
        if position + 1 < order.count { return position + 1 }
        return repeatMode == .all ? 0 : nil
    }

    /// What plays before `position`, wrapping to the end under repeat all.
    func position(before position: Int) -> Int? {
        if position > 0 { return position - 1 }
        return repeatMode == .all && !order.isEmpty ? order.count - 1 : nil
    }
}
