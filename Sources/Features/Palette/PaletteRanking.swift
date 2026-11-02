import Foundation
import FuzzyMatch

/// A listed item, with where its title matched.
public struct RankedItem: Sendable {
    public let index: Int
    public let item: PaletteItem
    let highlights: [NSRange]
}

/// Ranks items for a query as Searcher's 0085 does: the match score plus a frecency bonus, ties
/// broken by kind, then the larger bonus, then the shorter title, then the order given. Only the
/// best `limit` are kept, so 43k rows cost one score each and no full sort. An empty query lists
/// the most frecent first, then the rest in order. `byKind` lists every kind's best `limit` in
/// turn instead, in the kinds' order, so ⌘P shows artists, then albums, then tracks.
public func rankPalette(
    _ items: [PaletteItem], query: String, frecency: [String: Double], limit: Int,
    byKind: Bool = false
) -> [RankedItem] {
    let matcher = FuzzyMatcher(query)
    struct Entry {
        var index: Int
        var score: Int
        var kind: PaletteItem.Kind
        var bonus: Int
        var length: Int

        func beats(_ other: Entry) -> Bool {
            if score != other.score { return score > other.score }
            if kind != other.kind { return kind < other.kind }
            if bonus != other.bonus { return bonus > other.bonus }
            if length != other.length { return length < other.length }
            return index < other.index
        }
    }
    // One list, or one per kind, each holding its best `limit` in order.
    var lists: [[Entry]] = Array(repeating: [], count: byKind ? PaletteItem.Kind.allCases.count : 1)
    func offer(_ entry: Entry) {
        let list = byKind ? entry.kind.rawValue : 0
        let kept = lists[list]
        if kept.count == limit, let last = kept.last, !entry.beats(last) { return }
        var low = 0
        var high = kept.count
        while low < high {
            let middle = (low + high) / 2
            if kept[middle].beats(entry) { low = middle + 1 } else { high = middle }
        }
        lists[list].insert(entry, at: low)
        if lists[list].count > limit { lists[list].removeLast() }
    }
    if matcher.isEmpty {
        for (index, item) in items.enumerated() {
            let bonus = Frecency.bonus(frecency[item.key] ?? 0)
            offer(Entry(index: index, score: bonus, kind: item.kind, bonus: bonus, length: 0))
        }
        return lists.joined().map {
            RankedItem(index: $0.index, item: items[$0.index], highlights: [])
        }
    }
    let candidates = items.map(\.candidate)
    matcher.scoreAll(candidates) { index, score in
        let item = items[index]
        let bonus = frecency.isEmpty ? 0 : Frecency.bonus(frecency[item.key] ?? 0)
        offer(
            Entry(
                index: index, score: score + bonus, kind: item.kind, bonus: bonus,
                length: item.candidate.text.utf16.count))
    }
    return lists.joined().map { entry in
        let item = items[entry.index]
        return RankedItem(
            index: entry.index, item: item, highlights: matcher.highlights(item.candidate) ?? [])
    }
}
