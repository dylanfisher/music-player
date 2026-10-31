import Foundation

/// The palette's logic, apart from AppKit: the items listed, the query, and the ranked results.
/// Ranking runs off the main actor, and only the latest query's results are kept.
@MainActor
public final class PaletteModel {
    /// How many rows the palette lists.
    nonisolated public static let limit = 50

    public private(set) var items: [PaletteItem] = []
    public private(set) var query = ""
    public private(set) var results: [RankedItem] = []
    public private(set) var frecency: Frecency
    /// Called after `results` changes.
    public var resultsChanged: () -> Void = {}
    private var generation = 0
    private let now: () -> Double

    public init(frecency: Frecency, now: @escaping () -> Double = { Date().timeIntervalSince1970 })
    {
        self.frecency = frecency
        self.now = now
    }

    /// Replaces the items, as when the palette opens, and ranks them for the current query.
    public func setItems(_ items: [PaletteItem]) async {
        self.items = items
        await rank()
    }

    /// Adds items that arrived later, such as the library's artists.
    public func append(_ more: [PaletteItem]) async {
        items += more
        await rank()
    }

    public func setQuery(_ text: String) async {
        query = text
        await rank()
    }

    /// Counts a choice or a play of `key`.
    public func record(_ key: String) {
        frecency.record(key, now: now())
    }

    private func rank() async {
        generation += 1
        let mine = generation
        let (items, query, scores) = (items, query, frecency.scores(now: now()))
        let ranked = await Task.detached(priority: .userInitiated) {
            rankPalette(items, query: query, frecency: scores, limit: Self.limit)
        }.value
        guard mine == generation else { return }
        results = ranked
        resultsChanged()
    }
}
