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
    /// A Not Now or its undo that failed, said beside the day until Refresh or the next open.
    private(set) var notice: String?
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

    /// Reads today's albums: when the source opens, and on Refresh, which drop the notice; and
    /// after Not Now and its undo, which keep it.
    @discardableResult
    func read(keepingNotice: Bool = false) -> Task<Void, Never> {
        if !keepingNotice { notice = nil }
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

    /// Not Now on the day's albums of `albumIDs`, the others ignored: takes them out of the list
    /// at once, marks each for 30 days, then reads the day again, so the draw fills their place.
    /// The task answers the service's ids of the albums marked, for Undo; a mark that fails is
    /// said, and the read puts its album back.
    @discardableResult
    func notNow(_ albumIDs: [Int64]) -> Task<[String], Never>? {
        let chosen = albumIDs.compactMap { albums[$0] }
        guard let service = service(), !chosen.isEmpty else { return nil }
        notice = nil
        return Task {
            for id in albumIDs { albums[id] = nil }
            day?.albums.removeAll { album in chosen.contains { $0.id == album.id } }
            changed()
            do {
                _ = try await show(
                    self.albumIDs.compactMap { id in albums[id].map { (id, $0.title) } })
            } catch {
                notice = "couldn't take the albums out of the list: \(error)"
            }
            listed()
            var marked: [String] = []
            for album in chosen {
                do throws(RecommenderError) {
                    _ = try await service.notNow(album.id)
                    marked.append(album.id)
                } catch {
                    notice = "couldn't mark \(album.title) Not Now: \(error)"
                }
            }
            await read(keepingNotice: true).value
            return marked
        }
    }

    /// Undo of Not Now: removes the marks on the service's `ids`, then reads the day again.
    @discardableResult
    func undoNotNow(_ ids: [String]) -> Task<Void, Never>? {
        guard let service = service(), !ids.isEmpty else { return nil }
        notice = nil
        return Task {
            for id in ids {
                do throws(RecommenderError) {
                    _ = try await service.undoNotNow(id)
                } catch {
                    notice = "couldn't remove the Not Now mark: \(error)"
                }
            }
            await read(keepingNotice: true).value
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
