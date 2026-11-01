import Library

/// The track table's rows, fetched a page at a time as the table asks for them and kept for at
/// most `capacityPages` pages, so the table holds a few thousand rows however long the library.
/// The least recently used page goes first.
final class RowCache {
    private let pageSize: Int
    private let capacityPages: Int
    private let fetch: ([Int64]) throws -> [TrackRow]
    private var ids: [Int64] = []
    /// Rows by ID, per page of `ids`.
    private var pages: [Int: [Int64: TrackRow]] = [:]
    /// Page numbers, least recently used first.
    private var recency: [Int] = []

    /// `fetch` returns the rows for some IDs, leaving out those that are gone.
    init(
        pageSize: Int = 100, capacityPages: Int = 30,
        fetch: @escaping ([Int64]) throws -> [TrackRow]
    ) {
        precondition(pageSize > 0 && capacityPages > 0, "a row cache needs pages")
        self.pageSize = pageSize
        self.capacityPages = capacityPages
        self.fetch = fetch
    }

    /// The table's rows are now these IDs. Cached pages no longer line up, so they go.
    func setIDs(_ ids: [Int64]) {
        self.ids = ids
        pages = [:]
        recency = []
    }

    /// The row at `index`, fetching its page if it isn't cached. Nil when its track has gone
    /// from the index since the IDs were loaded.
    func row(at index: Int) throws -> TrackRow? {
        precondition(ids.indices.contains(index), "row \(index) is outside the table")
        let page = index / pageSize
        if let rows = pages[page] {
            if recency.last != page {
                recency.removeAll { $0 == page }
                recency.append(page)
            }
            return rows[ids[index]]
        }
        let range = (page * pageSize)..<min(ids.count, (page + 1) * pageSize)
        let rows = try fetch(Array(ids[range]))
        pages[page] = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        recency.append(page)
        while recency.count > capacityPages { pages[recency.removeFirst()] = nil }
        return pages[page]?[ids[index]]
    }
}
