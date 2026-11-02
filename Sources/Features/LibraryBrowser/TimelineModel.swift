import Foundation
import Library
import Log

private let logger = moduleLogger()

/// The play timeline's logic, apart from AppKit: every play, newest first, read a page at a
/// time by history ID (ADR 0022). Its rows are plays, so they're told apart by history ID, not
/// by track ID, which repeats.
///
/// The loaded plays are small entries; what a row shows is read through a cache of at most
/// `cachePages` pages, so scrolling through a million plays holds a few thousand tracks.
///
/// Each load starts a session; results of an earlier session are dropped. Other requests build
/// on the rows as they are when their results arrive, so overlapping ones neither duplicate nor
/// drop a row.
@MainActor
final class TimelineModel {
    static let pageSize = 200
    /// Pages of resolved rows kept: a few screens either side of the visible ones.
    static let cachePages = 20

    private(set) var entries: [PlayEntry] = []
    /// Whether the oldest play is loaded.
    private(set) var reachedEnd = false
    /// How many plays the history holds, loaded or not.
    private(set) var playCount = 0
    /// Whether the newest page has been read since the timeline last showed.
    private(set) var isLoaded = false
    /// Called after the rows or what they show change, with the history IDs shown before, so
    /// the view can find its selection again.
    var changed: (_ previousIDs: [Int64]) -> Void = { _ in }
    var failed: (String) -> Void = { _ in }

    private let reader: LibraryReader
    /// Reads the files and tracks of path IDs, on the main thread's own connection, for the
    /// rows as the table draws them.
    private let resolve: ([Int64]) throws -> [Int64: PlayedTrack]
    private var session = 0
    /// The session a page load is running for, so scrolling asks for each page once.
    private var loadingMore: Int?
    /// Resolved rows by row page, least recently used first; cleared whenever rows shift.
    private var pages: [Int: [Int64: PlayedTrack]] = [:]
    private var recency: [Int] = []

    init(
        reader: LibraryReader, resolve: @escaping ([Int64]) throws -> [Int64: PlayedTrack]
    ) {
        self.reader = reader
        self.resolve = resolve
    }

    /// Pages of resolved rows held now, for checking the cache stays bounded.
    var cachedPageCount: Int { pages.count }

    /// Reads the newest page, replacing what was loaded.
    func load() async {
        session += 1
        let mine = session
        do {
            let page = try await reader.timeline(before: nil, limit: Self.pageSize)
            let count = try await reader.loggedPlayCount()
            guard mine == session else { return }
            reachedEnd = page.count < Self.pageSize
            playCount = count
            isLoaded = true
            apply(page, forced: true)
        } catch {
            fail(mine, "couldn't read the play timeline: \(error)")
        }
    }

    /// Forgets the rows, as the timeline stops showing, so a later load starts fresh.
    func clear() {
        session += 1
        loadingMore = nil
        isLoaded = false
        apply([])
    }

    /// Reads the page after the oldest loaded row, unless one is already being read.
    func loadMore() async {
        guard !reachedEnd, loadingMore != session, let last = entries.last else { return }
        let mine = session
        loadingMore = mine
        defer { if loadingMore == mine { loadingMore = nil } }
        do {
            let page = try await reader.timeline(before: last.id, limit: Self.pageSize)
            guard mine == session else { return }
            if page.count < Self.pageSize { reachedEnd = true }
            // Rows that arrived meanwhile are only ever above, so the oldest is still last.
            let oldest = entries.last?.id ?? Int64.max
            apply(entries + page.filter { $0.id < oldest })
        } catch {
            fail(mine, "couldn't read more of the play timeline: \(error)")
        }
    }

    /// Adds plays logged since the newest loaded row above the rows. More than a page of them
    /// reloads, so no play is skipped between the two.
    func addNewPlays() async {
        guard let newest = entries.first else {
            await load()
            return
        }
        let mine = session
        do {
            let page = try await reader.timeline(after: newest.id, limit: Self.pageSize)
            let count = try await reader.loggedPlayCount()
            guard mine == session else { return }
            guard page.count < Self.pageSize else {
                await load()
                return
            }
            playCount = count
            let top = entries.first?.id ?? 0
            apply(page.filter { $0.id > top } + entries)
        } catch {
            fail(mine, "couldn't read the latest plays: \(error)")
        }
    }

    /// Reads what the rows show again after the library changed: a file that left the index
    /// shows as missing, and one that came back shows again. Only rows drawn again are read.
    func refresh() {
        pages = [:]
        recency = []
        changed(entries.map(\.id))
    }

    /// The file and track of the play at `row`, read with its page if that isn't cached.
    func played(at row: Int) throws -> PlayedTrack? {
        precondition(entries.indices.contains(row), "row \(row) is outside the timeline")
        let page = row / Self.pageSize
        if let rows = pages[page] {
            if recency.last != page {
                recency.removeAll { $0 == page }
                recency.append(page)
            }
            return rows[entries[row].trackID]
        }
        let range = (page * Self.pageSize)..<min(entries.count, (page + 1) * Self.pageSize)
        let rows = try resolve(entries[range].map(\.trackID))
        pages[page] = rows
        recency.append(page)
        while recency.count > Self.cachePages { pages[recency.removeFirst()] = nil }
        return rows[entries[row].trackID]
    }

    /// The rows now holding the plays `ids`, for keeping a selection across a change.
    func rows(holding ids: Set<Int64>) -> IndexSet {
        IndexSet(entries.indices.filter { ids.contains(entries[$0].id) })
    }

    /// The tracks of the plays at `rows`, each once, in row order, leaving out missing files:
    /// what rating, playlists and the tag editor act on. Throws `OnlyMissingFiles` when rows
    /// are given and none of them has a track, as do the other two.
    func trackIDs(ofRows rows: IndexSet) throws -> [Int64] {
        var seen = Set<Int64>()
        return try present(rows).map(\.entry.trackID).filter { seen.insert($0).inserted }
    }

    /// The files of the plays at `rows`, in row order, a track as often as its rows, leaving
    /// out missing files: what Play Next queues.
    func urls(ofRows rows: IndexSet) throws -> [URL] {
        try present(rows).map { URL(fileURLWithPath: $0.played.path, isDirectory: false) }
    }

    /// The queue a double-click on `clicked` plays, by the track table's rule, leaving out
    /// missing files. A missing clicked row starts at the next row that plays.
    func playRequest(selected: IndexSet, clicked: Int) throws -> PlayRequest? {
        let (rows, first) = playOrder(
            rowCount: entries.count, selected: selected, clicked: clicked)
        let played = try resolve(rows.map { entries[$0].trackID })
        var urls: [URL] = []
        var start: Int?
        for (position, row) in rows.enumerated() {
            guard let file = played[entries[row].trackID], file.track != nil else { continue }
            if start == nil, position >= first { start = urls.count }
            urls.append(URL(fileURLWithPath: file.path, isDirectory: false))
        }
        guard !urls.isEmpty else {
            if rows.isEmpty { return nil }
            throw OnlyMissingFiles()
        }
        return PlayRequest(urls: urls, first: start ?? 0)
    }

    private func present(_ rows: IndexSet) throws -> [(entry: PlayEntry, played: PlayedTrack)] {
        let picked = rows.filter { entries.indices.contains($0) }.map { entries[$0] }
        let played = try resolve(picked.map(\.trackID))
        let present = picked.compactMap { entry in
            played[entry.trackID].flatMap { $0.track == nil ? nil : (entry, $0) }
        }
        if present.isEmpty, !picked.isEmpty { throw OnlyMissingFiles() }
        return present
    }

    /// Takes `next` as the rows and reports it, unless nothing changed. Rows shifted by plays
    /// added above drop the cached pages, which are by row.
    private func apply(_ next: [PlayEntry], forced: Bool = false) {
        guard forced || next != entries else { return }
        let previous = entries.map(\.id)
        if next.first?.id != entries.first?.id || next.count < entries.count {
            pages = [:]
            recency = []
        }
        entries = next
        changed(previous)
    }

    private func fail(_ mine: Int, _ message: String) {
        guard mine == session else { return }
        logger.error("\(message)")
        failed(message)
    }
}
