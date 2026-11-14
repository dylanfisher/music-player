import Foundation
import Library
import Recommender

/// Threads' logic, apart from AppKit (ADR 0208): the seed asked for, the reply's albums mapped
/// to the index's by their profile key, the thread the table is narrowed to, and what went
/// wrong. Reading, mapping back and the errors are Rediscover's: each read sends the profile
/// first if it changed, and a seed or an album the service's profile doesn't have as this
/// Mac's sends this Mac's, forced, and asks once more. Each read takes a session number, so
/// one a newer read started after is dropped.
@MainActor
final class ThreadsModel {
    typealias Problem = RediscoverModel.Problem

    /// The album whose threads are shown or asked for; nil before Show Threads.
    private(set) var seed: Int64?
    /// The threads shown, as the service answered them for `seed`.
    private(set) var reply: AlbumThreads?
    /// The reply's albums the index has, by album id.
    private(set) var albums: [Int64: RediscoverDay.Album] = [:]
    /// The thread of the reply the table lists, by its place; nil for All.
    private(set) var chosen: Int?
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

    /// The call to the service as set now; nil while its address or token isn't set.
    var service: () -> ThreadsService? = { nil }
    /// Sends the profile, only if it changed unless forced.
    var sendProfile: (_ force: Bool) async -> ProfileSender.Outcome = { _ in .notSet }

    private let show: ([(id: Int64, title: String)]) async throws -> [Int64]
    private var session = 0
    /// Counts the lists given to the index, so a list an earlier choice made is dropped.
    private var listing = 0

    /// `show` lists albums for the `.threads` source, in order, and answers those the index
    /// doesn't have.
    init(show: @escaping ([(id: Int64, title: String)]) async throws -> [Int64]) {
        self.show = show
    }

    /// The selected album as the reply has it, if it's one of the reply's.
    var selected: RediscoverDay.Album? { selectedAlbumID.flatMap { albums[$0] } }

    /// The threads the selected album is in.
    var selectedThreads: [RediscoverDay.Thread] {
        guard let selected, let reply else { return [] }
        return reply.threads.filter { $0.ids.contains(selected.id) }
    }

    /// The albums the table lists, by album id: the chosen thread's in its order, or else every
    /// album of the reply in the reply's, each one the index has.
    var albumIDs: [Int64] {
        guard let reply else { return [] }
        let byService = Dictionary(
            albums.map { ($0.value.id, $0.key) }, uniquingKeysWith: { first, _ in first })
        let ids = chosen.map { reply.threads[$0].ids } ?? reply.albums.map(\.id)
        return ids.compactMap { byService[$0] }
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
                        continue
                    }
                    return finish(Problem(error), mine)
                }
                guard mine == session else { return }
                let unknown: Int
                do {
                    unknown = try await take(reply)
                } catch {
                    return finish(.failed("couldn't list the threads' albums: \(error)"), mine)
                }
                guard mine == session else { return }
                if unknown == 0 { return finish(nil, mine) }
                if sentAgain { return finish(.unknownAlbums(unknown), mine) }
                if case .failed(let why) = await sendProfile(true) {
                    return finish(.failed(why), mine)
                }
            }
        }
    }

    /// Lists only the albums of the reply's thread at `place`, or every album for nil.
    @discardableResult
    func choose(_ place: Int?) -> Task<Void, Never>? {
        guard let reply, place.map(reply.threads.indices.contains) ?? true, place != chosen
        else { return nil }
        chosen = place
        changed()
        return Task {
            do {
                try await list(albumIDs)
            } catch {
                problem = .failed("couldn't list the thread's albums: \(error)")
                changed()
            }
        }
    }

    /// Takes `reply` as the threads shown, lists those of its albums the index has, and
    /// answers how many it doesn't.
    private func take(_ reply: AlbumThreads) async throws -> Int {
        let keyed = reply.albums.compactMap { album in
            albumID(profileKey: album.key).map { (id: $0, album: album) }
        }
        listing += 1
        let mine = listing
        let missing = Set(try await show(keyed.map { ($0.id, $0.album.title) }))
        self.reply = reply
        chosen = nil
        albums = Dictionary(
            keyed.filter { !missing.contains($0.id) }.map { ($0.id, $0.album) },
            uniquingKeysWith: { first, _ in first })
        if mine == listing { listed() }
        return reply.albums.count - albums.count
    }

    /// Lists `ids` of the albums the model has, in order.
    private func list(_ ids: [Int64]) async throws {
        listing += 1
        let mine = listing
        _ = try await show(ids.compactMap { id in albums[id].map { (id, $0.title) } })
        if mine == listing { listed() }
    }

    private func finish(_ problem: Problem?, _ mine: Int) {
        guard mine == session else { return }
        self.problem = problem
        isReading = false
        changed()
    }
}
