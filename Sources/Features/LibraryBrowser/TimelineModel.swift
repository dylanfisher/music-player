import Foundation
import Library
import Log

private let logger = moduleLogger()

/// The play timeline's logic, apart from AppKit: every play, newest first, read a page at a
/// time by history ID (ADR 0022). Its rows are plays, so they're told apart by history ID, not
/// by track ID, which repeats.
///
/// Each load starts a session; results of an earlier session are dropped. Other requests build
/// on the rows as they are when their results arrive, so overlapping ones neither duplicate nor
/// drop a row.
@MainActor
public final class TimelineModel {
    public static let pageSize = 200

    public private(set) var entries: [PlayEntry] = []
    /// Whether the oldest play is loaded.
    public private(set) var reachedEnd = false
    /// How many plays the history holds, loaded or not.
    public private(set) var playCount = 0
    /// Called after the rows change, with the history IDs shown before, so the view can find
    /// its selection again.
    public var changed: (_ previousIDs: [Int64]) -> Void = { _ in }
    public var failed: (String) -> Void = { _ in }

    private let reader: LibraryReader
    private var session = 0
    /// The session a page load is running for, so scrolling asks for each page once.
    private var loadingMore: Int?

    public init(reader: LibraryReader) {
        self.reader = reader
    }

    /// Reads the newest page, replacing what was loaded.
    public func load() async {
        session += 1
        let mine = session
        do {
            let page = try await reader.timeline(before: nil, limit: Self.pageSize)
            let count = try await reader.loggedPlayCount()
            guard mine == session else { return }
            apply { entries in
                entries = page
                self.reachedEnd = page.count < Self.pageSize
                self.playCount = count
            }
        } catch {
            fail(mine, "couldn't read the play timeline: \(error)")
        }
    }

    /// Forgets the rows, as the timeline stops showing, so a later load starts fresh.
    public func clear() {
        session += 1
        loadingMore = nil
        apply { entries in entries = [] }
    }

    /// Reads the page after the oldest loaded row, unless one is already being read.
    public func loadMore() async {
        guard !reachedEnd, loadingMore != session, let last = entries.last else { return }
        let mine = session
        loadingMore = mine
        defer { if loadingMore == mine { loadingMore = nil } }
        do {
            let page = try await reader.timeline(before: last.id, limit: Self.pageSize)
            guard mine == session else { return }
            apply { entries in
                // Rows that arrived meanwhile are only ever above, so the oldest is still last.
                let oldest = entries.last?.id ?? Int64.max
                entries += page.filter { $0.id < oldest }
                if page.count < Self.pageSize { self.reachedEnd = true }
            }
        } catch {
            fail(mine, "couldn't read more of the play timeline: \(error)")
        }
    }

    /// Adds plays logged since the newest loaded row above the rows. More than a page of them
    /// reloads, so no play is skipped between the two.
    public func addNewPlays() async {
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
            apply { entries in
                let top = entries.first?.id ?? 0
                entries.insert(contentsOf: page.filter { $0.id > top }, at: 0)
                self.playCount = count
            }
        } catch {
            fail(mine, "couldn't read the latest plays: \(error)")
        }
    }

    /// Reads the loaded rows' tracks again after the library changed: a file that left the
    /// index shows as missing, and one that came back shows again.
    public func refresh() async {
        let mine = session
        do {
            let resolved = try await reader.resolved(entries)
            guard mine == session else { return }
            let tracks = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0.track) })
            apply { entries in
                for index in entries.indices {
                    if let track = tracks[entries[index].id] { entries[index].track = track }
                }
            }
        } catch {
            fail(mine, "couldn't read the play timeline's tracks: \(error)")
        }
    }

    /// The rows now holding the plays `ids`, for keeping a selection across a change.
    public func rows(holding ids: Set<Int64>) -> IndexSet {
        IndexSet(entries.indices.filter { ids.contains(entries[$0].id) })
    }

    /// The tracks of the plays at `rows`, each once, in row order, leaving out missing files:
    /// what rating, playlists and the tag editor act on.
    public func trackIDs(ofRows rows: IndexSet) -> [Int64] {
        var seen = Set<Int64>()
        return present(rows).map(\.trackID).filter { seen.insert($0).inserted }
    }

    /// The files of the plays at `rows`, in row order, a track as often as its rows, leaving
    /// out missing files: what Play Next queues.
    public func urls(ofRows rows: IndexSet) -> [URL] {
        present(rows).map { URL(fileURLWithPath: $0.path) }
    }

    /// The queue a double-click on `clicked` plays, by the track table's rule, leaving out
    /// missing files.
    public func playRequest(selected: IndexSet, clicked: Int) -> PlayRequest? {
        let (rows, first) = playOrder(
            rowCount: entries.count, selected: selected, clicked: clicked)
        var urls: [URL] = []
        // A missing clicked row starts at the next row that plays.
        var start: Int?
        for (position, row) in rows.enumerated() where entries[row].track != nil {
            if start == nil, position >= first { start = urls.count }
            urls.append(URL(fileURLWithPath: entries[row].path))
        }
        return urls.isEmpty ? nil : PlayRequest(urls: urls, first: start ?? 0)
    }

    private func present(_ rows: IndexSet) -> [PlayEntry] {
        rows.filter { entries.indices.contains($0) }.map { entries[$0] }.filter { $0.track != nil }
    }

    private func apply(_ change: (inout [PlayEntry]) -> Void) {
        let previous = entries.map(\.id)
        change(&entries)
        changed(previous)
    }

    private func fail(_ mine: Int, _ message: String) {
        guard mine == session else { return }
        logger.error("\(message)")
        failed(message)
    }
}
