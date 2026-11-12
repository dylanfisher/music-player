import DisplayText
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

    /// The lists the pop-up offers: the library's, then each seed asked for since launch.
    private(set) var seeds: [RecommendationQuery.Seed] = [.library]
    private(set) var query = RecommendationQuery()
    private(set) var rows: [RecommendationRow] = []
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
    private var reading: Task<Void, Never>?

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

    /// Shows `query`'s list from its first row, adding its seed to the pop-up's.
    @discardableResult
    func show(_ query: RecommendationQuery) -> Task<Void, Never>? {
        if !seeds.contains(query.seed) { seeds.append(query.seed) }
        self.query = query
        rows = []
        more = false
        facts = nil
        return read(from: 0, through: 0)
    }

    /// Reads the next page, while there is one and nothing is out or wrong.
    @discardableResult
    func readMore() -> Task<Void, Never>? {
        guard more, reading == nil, problem == nil else { return nil }
        return read(from: rows.count, through: 0)
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
        let before = rows
        let shown = rows.count
        stop()
        rows.removeAll { albums.contains(MarkedAlbum(kind: $0.album.kind, id: $0.album.id)) }
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
                rows = before.filter {
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
        let shown = rows.count + albums.count
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

    /// Stops the read out, for a closed window.
    func stop() {
        reading?.cancel()
        reading = nil
    }

    private func read(from offset: Int, through count: Int) -> Task<Void, Never>? {
        reading?.cancel()
        reading = nil
        problem = nil
        guard let service = service() else {
            problem = .notSet
            changed()
            return nil
        }
        let query = query
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
            self.rows = start == 0 ? read : self.rows + read
            more = page.more
            facts = page.list
            finish(problem: nil)
            return
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

    private static func problem(_ error: RecommenderError) -> ListProblem {
        switch error.kind {
        case .refused(let refusal): .refused(refusal)
        case .status(503, code: "busy"): .busy
        default: .failed(terminalSafe(error.description))
        }
    }
}

/// A master or release a mark is on.
struct MarkedAlbum: Equatable, Hashable, Sendable {
    var kind: AlbumKind
    var id: Int
}

/// `values` without repeats, in their first order.
private func distinct<Value: Hashable>(_ values: [Value]) -> [Value] {
    var seen: Set<Value> = []
    return values.filter { seen.insert($0).inserted }
}
