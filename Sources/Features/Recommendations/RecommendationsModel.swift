import DisplayText
import Foundation
import Recommender

/// The Recommendations window's list without the window: the query, the rows read so far and
/// what is pending or went wrong. Every read of a changed query starts from offset 0, and a
/// newer read cancels the one before; the service keeps a seed list it computes regardless.
@MainActor
final class RecommendationsModel {
    /// A 503 `busy` is asked again after this long, up to `busyRetries` times.
    static let busyRetrySeconds = 5.0
    static let busyRetries = 6
    /// An `out_of_date` list being scored again is asked for again this often while the window
    /// is open.
    static let rebuildingRetrySeconds = 30.0
    /// A discography whose values the service still fetches is asked for again this often
    /// while the window is open and shows it.
    static let fetchingRetrySeconds = 15.0

    /// The lists the pop-up offers: the library's, then each seed asked for since launch.
    private(set) var seeds: [RecommendationQuery.Seed] = [.library]
    private(set) var query = RecommendationQuery()
    /// The rows read, in the list's order.
    private var loaded: [RecommendationRow] = []
    /// Each list's header sort, by its seed, kept while the app runs (ADR 0218).
    private var headerSorts: [RecommendationQuery.Seed: HeaderSort] = [:]
    /// The rows shown: those read, without the library's albums when Missing is on for a
    /// discography, which the service lists whole (ADR 0217), in the header sort's order.
    var rows: [RecommendationRow] {
        let kept =
            query.seed.isDiscography && query.filters.missing
            ? loaded.filter { !$0.album.inLibrary } : loaded
        return headerSort.map { RecommendationColumn.sorted(kept, by: $0) } ?? kept
    }
    /// The list's header sort, nil for its own order.
    var headerSort: HeaderSort? { headerSorts[query.seed] }
    /// How many of a discography's releases the service will still fetch values for, as the
    /// last page said; nil for the scored lists.
    private(set) var pending: Int?
    /// Whether the list goes on past the rows read.
    private(set) var more = false
    private(set) var facts: RecommendationPage.Facts?
    private(set) var problem: ListProblem?
    /// A mark or undo that failed, said beside the rows.
    private(set) var notice: String?
    /// Whether a read is out.
    var isReading: Bool { reading != nil }
    /// Hears every change to what the model holds.
    var changed: () -> Void = {}

    private let service: () -> RecommendationsService?
    private let sleep: @Sendable (Double) async throws -> Void
    private(set) var reading: Task<Void, Never>?
    /// The wait before a discography whose values are coming in is read again, and that read.
    private(set) var refreshing: Task<Void, Never>?

    /// `sleep` waits between retries; tests pass one that doesn't.
    init(
        service: @escaping () -> RecommendationsService?,
        sleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.service = service
        self.sleep = sleep
    }

    /// Shows `query`'s list from its first row, adding its seed to the pop-up's. An order or
    /// view the seed's list doesn't offer becomes its default.
    @discardableResult
    func show(_ asked: RecommendationQuery) -> Task<Void, Never>? {
        let query = asked.fitted
        // An order chosen from the pop-up is the one shown.
        if query.seed == self.query.seed, query.sort != self.query.sort {
            headerSorts[query.seed] = nil
        }
        var others = query
        others.filters.missing = self.query.filters.missing
        if query.seed.isDiscography, others == self.query, !loaded.isEmpty {
            self.query = query
            changed()
            return readMoreToShow()
        }
        if !seeds.contains(query.seed) { seeds.append(query.seed) }
        self.query = query
        notice = nil
        loaded = []
        more = false
        facts = nil
        pending = nil
        return read(from: 0, through: 0)
    }

    /// Reads the next page, while there is one and nothing is out or wrong.
    @discardableResult
    func readMore() -> Task<Void, Never>? {
        guard more, reading == nil, problem == nil else { return nil }
        return read(from: loaded.count, through: 0)
    }

    /// Sorts the list by `sort`'s column, or back to its own order for nil, and reads the
    /// pages not read yet: a sort of part of the list would look like the whole (ADR 0218).
    @discardableResult
    func sort(by sort: HeaderSort?) -> Task<Void, Never>? {
        if let sort {
            precondition(sort.column.sorts(query), "\(sort.column) doesn't sort this list")
        }
        headerSorts[query.seed] = sort
        changed()
        return readMoreToShow()
    }

    /// Reads the list again from its first row through at least `count` rows, a page at a
    /// time, in place of the rows there.
    @discardableResult
    func readAgain(through count: Int) -> Task<Void, Never>? {
        read(from: 0, through: count)
    }

    /// Sets `verdict` on the albums of `marked` (on the Artists view, each artist's best),
    /// taking their rows out at once, then reads the list again through as many rows as it
    /// showed, since the cap of 3 to an artist or label can bring back an album the read
    /// before left out. A mark that fails puts its rows back and says why. The task answers
    /// the albums marked, for Undo.
    @discardableResult
    func mark(_ marked: [RecommendationRow], _ verdict: FeedbackMark.Verdict)
        -> Task<[MarkedAlbum], Never>?
    {
        guard let service = service() else {
            problem = .notSet
            changed()
            return nil
        }
        let albums = distinct(marked.map { MarkedAlbum(kind: $0.album.kind, id: $0.album.id) })
        let before = loaded
        let shown = loaded.count
        stop()
        loaded.removeAll { albums.contains(MarkedAlbum(kind: $0.album.kind, id: $0.album.id)) }
        notice = nil
        changed()
        return Task {
            var set: [MarkedAlbum] = []
            for album in albums {
                do throws(RecommenderError) {
                    _ = try await service.mark(album.kind, album.id, verdict)
                    set.append(album)
                } catch {
                    notice = "Couldn't mark the album: \(terminalSafe(error.description))"
                }
            }
            if set.count < albums.count {
                loaded = before.filter {
                    !set.contains(MarkedAlbum(kind: $0.album.kind, id: $0.album.id))
                }
            }
            await readAgain(through: shown)?.value
            return set
        }
    }

    /// Removes the marks on `albums`, for Undo, and reads the list again.
    @discardableResult
    func unmark(_ albums: [MarkedAlbum]) -> Task<Void, Never>? {
        guard let service = service() else { return nil }
        let shown = loaded.count + albums.count
        stop()
        return Task {
            for album in albums {
                do throws(RecommenderError) {
                    _ = try await service.unmark(album.kind, album.id)
                } catch {
                    notice = "Couldn't undo the mark: \(terminalSafe(error.description))"
                }
            }
            await readAgain(through: shown)?.value
        }
    }

    /// Says `text` beside the rows until the next list or mark.
    func tell(_ text: String) {
        notice = text
        changed()
    }

    /// The rows of `rows` that `filter`, the window's search field, keeps, matched on the text
    /// `columns`, those shown, show; `downloads` is the Download column's states.
    nonisolated static func filtered(
        _ rows: [RecommendationRow], by filter: ListFilter, columns: [RecommendationColumn],
        downloads: [Int: String]
    ) -> [RecommendationRow] {
        guard !filter.isEmpty else { return rows }
        return rows.filter { row in
            filter.matches(columns.map { $0.text(row, downloads: downloads) })
        }
    }

    /// Says `notice` beside the rows, as a mark that failed does, or with nil says none.
    func show(notice: String?) {
        guard notice != self.notice else { return }
        self.notice = notice
        changed()
    }

    /// Stops the read out, and the wait to read a discography again, for a closed window.
    func stop() {
        reading?.cancel()
        reading = nil
        refreshing?.cancel()
        refreshing = nil
    }

    /// Waits to read a discography again, for a window opened again, while its values are
    /// still coming in and nothing else is out.
    func resume() {
        guard reading == nil, refreshing == nil, problem == nil else { return }
        refreshIfFetching()
    }

    private func read(from offset: Int, through count: Int) -> Task<Void, Never>? {
        reading?.cancel()
        reading = nil
        refreshing?.cancel()
        refreshing = nil
        problem = nil
        guard let service = service() else {
            problem = .notSet
            changed()
            return nil
        }
        let query = query
        // A sorted list is read whole, so a refresh or the next page reads every page left.
        let count = headerSort == nil ? count : .max
        let task = Task { await fetch(service, query, from: offset, through: count) }
        reading = task
        changed()
        return task
    }

    private func fetch(
        _ service: RecommendationsService, _ query: RecommendationQuery, from start: Int,
        through count: Int
    ) async {
        var read: [RecommendationRow] = []
        var busyTries = 0
        while true {
            let page: RecommendationPage
            do throws(RecommenderError) {
                page = try await service.page(
                    query, start + read.count, RecommenderClient.pageLimit)
            } catch {
                guard !Task.isCancelled else { return }
                if case .status(503, code: "busy") = error.kind,
                    busyTries < Self.busyRetries
                {
                    busyTries += 1
                    guard await waited(Self.busyRetrySeconds) else { return }
                    continue
                }
                if case .refused(let refusal) = error.kind, refusal.code == .outOfDate,
                    refusal.rebuilding == true
                {
                    problem = .refused(refusal)
                    changed()
                    guard await waited(Self.rebuildingRetrySeconds) else { return }
                    problem = nil
                    continue
                }
                finish(problem: Self.problem(error))
                return
            }
            guard !Task.isCancelled else { return }
            let rows = RecommendationRow.rows(of: page)
            read += rows
            if page.more, !rows.isEmpty, read.count < count { continue }
            loaded = start == 0 ? read : loaded + read
            more = page.more
            facts = page.list
            pending = page.pending
            // Asking for the next page again would get the same empty one, without end.
            if page.more, rows.isEmpty {
                finish(problem: .failed(Self.emptyPage(at: start + read.count)))
                return
            }
            finish(problem: nil)
            readMoreToShow()
            refreshIfFetching()
            return
        }
    }

    /// Reads the next page of a discography while a header sorts it, or while Missing leaves
    /// fewer rows than a page, so a run of the library's albums can't leave the window
    /// nothing to scroll to.
    @discardableResult
    private func readMoreToShow() -> Task<Void, Never>? {
        guard query.seed.isDiscography,
            headerSort != nil
                || (query.filters.missing && rows.count < RecommenderClient.pageLimit)
        else { return nil }
        return readMore()
    }

    /// Reads the rows read so far again after a while, as the service fetches a
    /// discography's values and its order changes with them.
    private func refreshIfFetching() {
        // A read out arms the wait itself when it ends, so there is only ever one.
        guard let pending, pending > 0, reading == nil else { return }
        refreshing?.cancel()
        refreshing = Task {
            guard await waited(Self.fetchingRetrySeconds) else { return }
            refreshing = nil
            await readAgain(through: loaded.count)?.value
        }
    }

    /// Whether `seconds` went by without the read being cancelled.
    private func waited(_ seconds: Double) async -> Bool {
        do {
            try await sleep(seconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    private func finish(problem: ListProblem?) {
        self.problem = problem
        reading = nil
        changed()
    }

    /// Says the service sent no rows at `offset` though it said more follow.
    static func emptyPage(at offset: Int) -> String {
        "The service sent no albums from row \(offset + 1) on, though it said more follow."
    }

    private static func problem(_ error: RecommenderError) -> ListProblem {
        switch error.kind {
        case .refused(let refusal): .refused(refusal)
        case .status(503, code: "busy"): .busy
        case .status(404, code: "unknown_artist"): .unknownArtist
        case .badRequest(code: "various_artists", _): .variousArtists
        default: .failed(terminalSafe(error.description))
        }
    }
}

/// A master or release a mark is on.
struct MarkedAlbum: Equatable, Hashable, Sendable {
    var kind: AlbumKind
    var id: Int
}

/// The rows of `rows` whose albums are `albums`, for a selection kept as a list read again
/// reorders.
func rowsOf(_ albums: Set<MarkedAlbum>, in rows: [RecommendationRow]) -> IndexSet {
    IndexSet(
        rows.indices.filter {
            albums.contains(MarkedAlbum(kind: rows[$0].album.kind, id: rows[$0].album.id))
        })
}

/// `values` without repeats, in their first order.
private func distinct<Value: Hashable>(_ values: [Value]) -> [Value] {
    var seen: Set<Value> = []
    return values.filter { seen.insert($0).inserted }
}
