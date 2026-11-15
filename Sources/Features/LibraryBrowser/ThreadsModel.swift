import Foundation
import Library
import Recommender

/// Threads' logic, apart from AppKit (ADR 0208): the seed asked for, the reply's albums mapped
/// to the index's by their profile key, the thread the table is narrowed to, and what went
/// wrong. Reading, mapping back and the errors are Rediscover's: each read sends the profile
/// first if it changed, and a seed or an album the service's profile doesn't have as this
/// Mac's sends this Mac's, forced, and asks once more. Each read takes a session number, so
/// one a newer read started after is dropped. The panel's filters (ADR 0209) apply to the
/// reply held, so changing one reads nothing.
@MainActor
final class ThreadsModel {
    typealias Problem = RediscoverModel.Problem

    /// The album whose threads are shown or asked for; nil before Show Threads.
    private(set) var seed: Int64?
    /// The threads shown, as the service answered them for `seed`.
    private(set) var reply: AlbumThreads?
    /// The reply's albums the index has, by album id.
    private(set) var albums: [Int64: RediscoverDay.Album] = [:]
    /// What the threads list under `filter`, read with `reply`.
    private(set) var shown: ShownThreads?
    /// The thread of the reply the table lists, by its place; nil for All.
    private(set) var chosen: Int?
    private(set) var filter = ThreadsFilter.defaults
    private(set) var problem: Problem?
    private(set) var isReading = false
    /// The album of the first selected track, whose threads the panel shows.
    var selectedAlbumID: Int64? {
        didSet { if selectedAlbumID != oldValue { changed() } }
    }
    /// Whether the source shows, so it reads again only when it starts showing.
    var isOpen = false
    /// Hears every change to what the model holds.
    var changed: () -> Void = {}
    /// Hears that the index lists another set of albums, for the table to read again.
    var listed: () -> Void = {}
    /// Hears the filters chosen in the panel, for the settings to keep.
    var filterChosen: (ThreadsFilter) -> Void = { _ in }

    /// The call to the service as set now; nil while its address or token isn't set.
    var service: () -> ThreadsService? = { nil }
    /// Sends the profile, only if it changed unless forced.
    var sendProfile: (_ force: Bool) async -> ProfileSender.Outcome = { _ in .notSet }

    private let show: ([(id: Int64, title: String)], Set<Int64>) async throws -> [Int64]
    /// For Not in a Year.
    private let now: () -> Date
    private var session = 0
    /// Counts the lists given to the index, so a list an earlier choice made is dropped.
    private var listing = 0

    /// `show` lists those of its albums in its set for the `.threads` source, in order, and
    /// answers those of all of them the index doesn't have; `now` is when Not in a Year counts
    /// back from.
    init(
        show: @escaping ([(id: Int64, title: String)], Set<Int64>) async throws -> [Int64],
        now: @escaping () -> Date = Date.init
    ) {
        self.show = show
        self.now = now
    }

    /// The selected album as the reply has it, if it's one of the reply's.
    var selected: RediscoverDay.Album? { selectedAlbumID.flatMap { albums[$0] } }

    /// The threads of the kinds shown the selected album is in.
    var selectedThreads: [RediscoverDay.Thread] {
        guard let selected, let shown else { return [] }
        return shown.threads.map(\.thread).filter { $0.ids.contains(selected.id) }
    }

    /// The albums the table lists, by album id: the chosen thread's that pass the filters in
    /// its order, or else All's in the reply's, each one the index has.
    var albumIDs: [Int64] {
        guard let shown else { return [] }
        let byService = Dictionary(
            albums.map { ($0.value.id, $0.key) }, uniquingKeysWith: { first, _ in first })
        let ids = chosen.flatMap { place in shown.threads.first { $0.place == place }?.ids }
        return (ids ?? shown.albums).compactMap { byService[$0] }
    }

    /// Reads the threads of `seed`: when Threads starts showing, when its seed changes, and on
    /// Refresh. Another seed's threads are cleared at once; the same seed's stay under an
    /// error. The reply read lists All.
    @discardableResult
    func read(_ seed: Int64) -> Task<Void, Never> {
        session += 1
        let mine = session
        let isNew = seed != self.seed
        self.seed = seed
        if isNew {
            chosen = nil
            reply = nil
            shown = nil
            albums = [:]
            problem = nil
        }
        return Task {
            if isNew {
                do {
                    try await list([])
                } catch {
                    return finish(.failed("couldn't empty the list: \(error)"), mine)
                }
            }
            guard let service = service() else { return finish(.notSet, mine) }
            isReading = true
            changed()
            if case .failed(let why) = await sendProfile(false) {
                return finish(.failed(why), mine)
            }
            for sentAgain in [false, true] {
                let reply: AlbumThreads
                do throws(RecommenderError) {
                    reply = try await service.threads(profileKey(albumID: seed))
                } catch {
                    // The service's profile has no album keyed so: another Mac's, or one from
                    // before a rebuild numbered the albums again.
                    if case .refused(let refusal) = error.kind, refusal.code == .noSeed,
                        !sentAgain
                    {
                        if case .failed(let why) = await sendProfile(true) {
                            return finish(.failed(why), mine)
                        }
                        guard mine == session else { return }
                        continue
                    }
                    return finish(Problem(error), mine)
                }
                guard mine == session else { return }
                let taken: Int?
                do {
                    taken = try await take(reply, mine)
                } catch {
                    return finish(.failed("couldn't list the threads' albums: \(error)"), mine)
                }
                guard let unknown = taken else { return }
                if unknown == 0 { return finish(nil, mine) }
                if sentAgain { return finish(.unknownAlbums(unknown), mine) }
                if case .failed(let why) = await sendProfile(true) {
                    return finish(.failed(why), mine)
                }
            }
        }
    }

    /// Lists only the albums of the reply's thread at `place`, or All's for nil. A thread
    /// not listed or emptied by the filters can't be chosen.
    @discardableResult
    func choose(_ place: Int?) -> Task<Void, Never>? {
        guard let shown, place.map({ isChoosable($0, in: shown) }) ?? true, place != chosen
        else { return nil }
        chosen = place
        changed()
        return relist()
    }

    /// Takes `filter` as the panel's filters and lists what they pass of the reply held; a
    /// chosen thread they hide or empty goes back to All.
    @discardableResult
    func apply(_ filter: ThreadsFilter) -> Task<Void, Never>? {
        guard filter != self.filter else { return nil }
        self.filter = filter
        guard let reply else {
            changed()
            return nil
        }
        let shown = reply.shown(by: filter, now: now())
        self.shown = shown
        if let chosen, !isChoosable(chosen, in: shown) { self.chosen = nil }
        changed()
        return relist()
    }

    /// Whether the reply's thread at `place` is listed with an album or more that pass.
    private func isChoosable(_ place: Int, in shown: ShownThreads) -> Bool {
        shown.threads.contains { $0.place == place && !$0.ids.isEmpty }
    }

    /// Lists `albumIDs` for the table.
    private func relist() -> Task<Void, Never> {
        Task {
            do {
                try await list(albumIDs)
            } catch {
                problem = .failed("couldn't list the thread's albums: \(error)")
                changed()
            }
        }
    }

    /// Takes `reply` as the threads shown, lists those of its albums the index has that the
    /// filters pass, and answers how many of all its albums the index doesn't have; nil,
    /// taking nothing, when a newer read than `session` started while the index listed them.
    private func take(_ reply: AlbumThreads, _ session: Int) async throws -> Int? {
        let keyed = reply.albums.compactMap { album in
            albumID(profileKey: album.key).map { (id: $0, album: album) }
        }
        // The index checks every album, to say which it lacks, and lists only those the
        // filters pass.
        let passing = Set(reply.shown(by: filter, now: now()).albums)
        let filter = self.filter
        listing += 1
        let mine = listing
        let missing = Set(
            try await show(
                keyed.map { ($0.id, $0.album.title) },
                Set(keyed.filter { passing.contains($0.album.id) }.map(\.id))))
        guard session == self.session else { return nil }
        self.reply = reply
        shown = reply.shown(by: self.filter, now: now())
        chosen = nil
        albums = Dictionary(
            keyed.filter { !missing.contains($0.id) }.map { ($0.id, $0.album) },
            uniquingKeysWith: { first, _ in first })
        // A filter changed, or another list was given, while the index listed these: what it
        // holds may not be this reply's.
        if mine != listing || filter != self.filter {
            try await list(albumIDs)
        } else {
            listed()
        }
        return reply.albums.count - albums.count
    }

    /// Lists `ids` of the albums the model has, in order.
    private func list(_ ids: [Int64]) async throws {
        listing += 1
        let mine = listing
        _ = try await show(ids.compactMap { id in albums[id].map { (id, $0.title) } }, Set(ids))
        if mine == listing { listed() }
    }

    private func finish(_ problem: Problem?, _ mine: Int) {
        guard mine == session else { return }
        self.problem = problem
        isReading = false
        changed()
    }
}
