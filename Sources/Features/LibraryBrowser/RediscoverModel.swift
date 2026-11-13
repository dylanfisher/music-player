import Foundation
import Library
import Recommender

/// Rediscover's logic, apart from AppKit (ADR 0206): the day asked for, its albums mapped to
/// the index's by their profile key, and what went wrong. Each read sends the profile first if
/// it changed since the last send. A key the index doesn't have under the album's title means
/// the service keeps another Mac's profile, or one from before a rebuild, so this Mac's is sent
/// and the day asked for once more; keys still unknown after that are an error. Each read takes
/// a session number, so one a newer read started after is dropped.
@MainActor
final class RediscoverModel {
    /// Why the panel shows no day, or not all of it.
    enum Problem: Equatable {
        /// The service's address or token isn't set.
        case notSet
        /// The service understood the request and refused it, with its code.
        case refused(ServiceRefusal)
        /// Any other error, as its text, which names the address.
        case failed(String)
        /// This many of the day's albums aren't in this library, even after its profile was
        /// sent again.
        case unknownAlbums(Int)
    }

    /// The day shown, as the service answered it.
    private(set) var day: RediscoverDay?
    /// The day's albums the index has, by album id.
    private(set) var albums: [Int64: RediscoverDay.Album] = [:]
    private(set) var problem: Problem?
    private(set) var isReading = false
    /// The album of the first selected track, whose reasons the panel shows.
    var selectedAlbumID: Int64? {
        didSet { if selectedAlbumID != oldValue { changed() } }
    }
    /// Whether the source shows, so it reads again only when it starts showing.
    var isOpen = false
    /// Hears every change to what the model holds.
    var changed: () -> Void = {}
    /// Hears that the index lists another set of albums, for the table to read again.
    var listed: () -> Void = {}

    /// The calls to the service as set now; nil while its address or token isn't set.
    var service: () -> RediscoverService? = { nil }
    /// Sends the profile, only if it changed unless forced.
    var sendProfile: (_ force: Bool) async -> ProfileSender.Outcome = { _ in .notSet }

    private let show: ([(id: Int64, title: String)]) async throws -> [Int64]
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private var session = 0

    /// `show` lists albums for the `.rediscover` source and answers those the index doesn't
    /// have; `now` and `timeZone` make the day asked for.
    init(
        show: @escaping ([(id: Int64, title: String)]) async throws -> [Int64],
        now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.show = show
        self.now = now
        self.timeZone = timeZone
    }

    /// The selected album as the day has it, if it's one of the day's.
    var selected: RediscoverDay.Album? { selectedAlbumID.flatMap { albums[$0] } }

    /// The day's albums the index has, best first.
    var albumIDs: [Int64] {
        guard let day else { return [] }
        return day.albums.compactMap { album in
            albumID(profileKey: album.key).flatMap { albums[$0] == nil ? nil : $0 }
        }
    }

    /// Reads today's albums: when the source opens, and on Refresh.
    @discardableResult
    func read() -> Task<Void, Never> {
        session += 1
        let mine = session
        return Task {
            guard let service = service() else { return finish(.notSet, mine) }
            isReading = true
            changed()
            let today = RediscoverDay.day(of: now(), in: timeZone())
            if case .failed(let why) = await sendProfile(false) {
                return finish(.failed(why), mine)
            }
            for sentAgain in [false, true] {
                let reply: RediscoverDay
                do throws(RecommenderError) {
                    reply = try await service.day(today)
                } catch {
                    return finish(problem(error), mine)
                }
                guard mine == session else { return }
                let unknown: Int
                do {
                    unknown = try await list(reply)
                } catch {
                    return finish(.failed("couldn't list the day's albums: \(error)"), mine)
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

    /// Lists the day's albums the index has, and answers how many it doesn't.
    private func list(_ reply: RediscoverDay) async throws -> Int {
        let keyed = reply.albums.compactMap { album in
            albumID(profileKey: album.key).map { (id: $0, album: album) }
        }
        let missing = Set(try await show(keyed.map { ($0.id, $0.album.title) }))
        day = reply
        albums = Dictionary(
            keyed.filter { !missing.contains($0.id) }.map { ($0.id, $0.album) },
            uniquingKeysWith: { first, _ in first })
        listed()
        return reply.albums.count - albums.count
    }

    private func finish(_ problem: Problem?, _ mine: Int) {
        guard mine == session else { return }
        self.problem = problem
        isReading = false
        changed()
    }

    private func problem(_ error: RecommenderError) -> Problem {
        if case .refused(let refusal) = error.kind { return .refused(refusal) }
        return .failed("\(error)")
    }
}
