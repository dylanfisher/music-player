import Library
import Log

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
    /// Each cached page's album IDs, by position in the page, so the art column's scans of
    /// neighboring rows don't copy whole rows.
    private var albumIDs: [Int: [Int64?]] = [:]
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
        albumIDs = [:]
        recency = []
    }

    /// The row at `index` if its page is cached, without fetching it or counting as a use.
    func cachedRow(at index: Int) -> TrackRow? {
        precondition(ids.indices.contains(index), "row \(index) is outside the table")
        return pages[index / pageSize]?[ids[index]]
    }

    /// The row at `index`, fetching its page if it isn't cached. Nil when its track has gone
    /// from the index since the IDs were loaded.
    func row(at index: Int) throws -> TrackRow? {
        pages[try usedPage(of: index)]?[ids[index]]
    }

    /// The album ID of the row at `index`, fetching its page as `row(at:)` does. Nil when the
    /// row has no album or its track has gone.
    func albumID(at index: Int) throws -> Int64? {
        let page = try usedPage(of: index)
        return albumIDs[page]?[index - page * pageSize] ?? nil
    }

    /// The page holding `index`, fetched if it isn't cached, and counted as the latest use.
    private func usedPage(of index: Int) throws -> Int {
        precondition(ids.indices.contains(index), "row \(index) is outside the table")
        let page = index / pageSize
        if pages[page] != nil {
            if recency.last != page {
                recency.removeAll { $0 == page }
                recency.append(page)
            }
            return page
        }
        let range = (page * pageSize)..<min(ids.count, (page + 1) * pageSize)
        let rows = try signposted(.pageFetch) { try fetch(Array(ids[range])) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        pages[page] = byID
        albumIDs[page] = ids[range].map { byID[$0]?.albumID }
        recency.append(page)
        while recency.count > capacityPages {
            let evicted = recency.removeFirst()
            pages[evicted] = nil
            albumIDs[evicted] = nil
        }
        return page
    }
}
