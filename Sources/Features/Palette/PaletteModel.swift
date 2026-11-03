import Foundation

/// The palette's logic, apart from AppKit: the items listed, the query, and the ranked results.
/// Ranking runs off the main actor, and only the latest query's results are kept.
@MainActor
public final class PaletteModel {
    /// How many rows the palette lists.
    nonisolated public static let limit = 50

    public private(set) var items: [PaletteItem] = []
    public private(set) var query = ""
    /// Whether the listing ranks each kind in turn, as `rankPalette` does with `byKind`.
    public private(set) var byKind = false
    /// The only kinds the empty query lists, as `rankPalette` takes them; nil lists every kind.
    private var emptyQueryKinds: Set<PaletteItem.Kind>?
    public private(set) var results: [RankedItem] = []
    public private(set) var frecency: Frecency
    /// Counts the listings `open` starts, so items read for one aren't added to the next.
    public private(set) var session = 0
    /// Called after `results` changes, with whether they rank the same query of the same
    /// listing as before, as when items were appended.
    var resultsChanged: (_ sameQuery: Bool) -> Void = { _ in }
    private var generation = 0
    /// The session and query `results` were ranked for.
    private var ranked: (session: Int, query: String)?
    private let now: () -> Double

    public init(frecency: Frecency, now: @escaping () -> Double = { Date().timeIntervalSince1970 })
    {
        self.frecency = frecency
        self.now = now
    }

    /// Starts a listing of `items` with an empty query, as when the palette opens, and returns
    /// its session. The change is made before this returns, so an `append` made after builds on
    /// it. Call `rank` or `rankNow` to rank it.
    public func open(
        _ items: [PaletteItem], byKind: Bool, emptyQueryKinds: Set<PaletteItem.Kind>? = nil
    ) -> Int {
        session += 1
        self.items = items
        self.byKind = byKind
        self.emptyQueryKinds = emptyQueryKinds
        query = ""
        return session
    }

    /// Adds items that arrived later for listing `session`, such as the library's artists.
    /// Items for a listing that has since been replaced are dropped.
    public func append(_ more: [PaletteItem], to session: Int) async {
        guard session == self.session else { return }
        items += more
        await rank()
    }

    package func setQuery(_ text: String) async {
        query = text
        await rank()
    }

    /// Counts a choice or a play of `key`.
    public func record(_ key: String) {
        frecency.record(key, now: now())
    }

    /// Ranks the items for the query. Only the latest call's results are kept.
    func rank() async {
        generation += 1
        let mine = generation
        let (items, query, session) = (items, query, session)
        let (byKind, kinds) = (byKind, emptyQueryKinds)
        let scores = frecency.scores(now: now())
        let results = await Task.detached(priority: .userInitiated) {
            rankPalette(
                items, query: query, frecency: scores, limit: Self.limit, byKind: byKind,
                emptyQueryKinds: kinds)
        }.value
        guard mine == generation else { return }
        publish(results, session: session, query: query)
    }

    /// Ranks the items for the query before this returns, so the palette has its rows before
    /// its first frame. Only for a listing that ranks in well under a frame, as an empty query
    /// does: it matches nothing, so even ⌘P's 43k kept rows take a few milliseconds. A ranking
    /// still running is dropped.
    func rankNow() {
        generation += 1
        publish(
            rankPalette(
                items, query: query, frecency: frecency.scores(now: now()), limit: Self.limit,
                byKind: byKind, emptyQueryKinds: emptyQueryKinds),
            session: session, query: query)
    }

    private func publish(_ results: [RankedItem], session: Int, query: String) {
        let sameQuery = ranked.map { $0 == (session, query) } ?? false
        self.results = results
        ranked = (session, query)
        resultsChanged(sameQuery)
    }
}
