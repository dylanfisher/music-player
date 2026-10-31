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

    // MARK: Edits, in play order

    /// Puts `urls` at `position` in play order, before what is there now. Off shuffle they join
    /// the listed queue at the same place; on shuffle they're listed last. Returns where each old
    /// position went.
    mutating func insert(_ urls: [URL], at position: Int) -> [Int?] {
        precondition((0...order.count).contains(position), "position \(position) is outside")
        return rebuild(
            (0..<position).map(Item.kept) + urls.map(Item.added)
                + (position..<order.count).map(Item.kept))
    }

    /// Moves the tracks at `positions` to just before `destination`, a position counted before
    /// the move, keeping their order. Returns where each old position went.
    mutating func move(_ positions: IndexSet, to destination: Int) -> [Int?] {
        precondition((0...order.count).contains(destination), "destination is outside")
        let moving = positions.filter { order.indices.contains($0) }
        let staying = order.indices.filter { !positions.contains($0) }
        let split = destination - moving.filter { $0 < destination }.count
        return rebuild(
            (staying[..<split] + moving + staying[split...]).map(Item.kept))
    }

    /// Removes the tracks at `positions`. Returns where each old position went, nil for those
    /// removed.
    mutating func remove(_ positions: IndexSet) -> [Int?] {
        rebuild(order.indices.filter { !positions.contains($0) }.map(Item.kept))
    }

    private enum Item {
        /// The track at this position before the edit.
        case kept(Int)
        case added(URL)
    }

    /// Makes `items` the new play order. Off shuffle the listed queue is the play order, so it
    /// stays that way and turning shuffle on later starts from the edited order.
    private mutating func rebuild(_ items: [Item]) -> [Int?] {
        var moved = [Int?](repeating: nil, count: order.count)
        for (position, item) in items.enumerated() {
            if case .kept(let old) = item { moved[old] = position }
        }
        if shuffle {
            let kept = Set(
                items.compactMap { item -> Int? in
                    if case .kept(let old) = item { return order[old] }
                    return nil
                })
            var listed: [URL] = []
            var renumbered: [Int: Int] = [:]
            for entry in entries.indices where kept.contains(entry) {
                renumbered[entry] = listed.count
                listed.append(entries[entry])
            }
            var played: [Int] = []
            for item in items {
                switch item {
                case .kept(let old): played.append(renumbered[order[old]]!)
                case .added(let url):
                    played.append(listed.count)
                    listed.append(url)
                }
            }
            entries = listed
            order = played
        } else {
            entries = items.map { item in
                switch item {
                case .kept(let old): entries[order[old]]
                case .added(let url): url
                }
            }
            order = Array(entries.indices)
        }
        return moved
    }
}
