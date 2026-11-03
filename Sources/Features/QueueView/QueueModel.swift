import Foundation
import Library
import Log
import Playback

private let logger = moduleLogger()

/// The queue panel's rows: the engine's queue in play order from the current track on, each
/// described from the library. Played tracks stay in the engine's queue, for Previous and repeat
/// all, but aren't listed. Row 0 is the current track, when there is one.
@MainActor
public final class QueueModel {
    /// The most rows whose library lookups are kept. A queue can hold the whole library, but the
    /// panel only ever shows a screenful.
    static let lookupCapacity = 2000

    public private(set) var state = PlaybackState()
    private let lookup: (String) throws -> TrackRow?
    private var described: [String: QueueItem] = [:]

    /// `lookup` finds a file's row by path.
    public init(lookup: @escaping (String) throws -> TrackRow?) {
        self.lookup = lookup
    }

    /// Takes the engine's new state. Returns how many rows left the top when the current track
    /// only moved further down the same play order, as it does when a track ends or on Next, so
    /// the rows below stay as they were; nil after any other change.
    @discardableResult
    func apply(_ state: PlaybackState) -> Int? {
        let previous = (state: self.state, position: currentPosition)
        self.state = state
        currentPosition = state.currentIndex.flatMap { state.order.firstIndex(of: $0) }
        guard let from = previous.position, let to = currentPosition, to > from,
            state.order == previous.state.order, state.queue == previous.state.queue
        else { return nil }
        return to - from
    }

    /// Forgets every row it described, after a rescan may have changed their tags.
    public func libraryChanged() {
        described = [:]
    }

    public var count: Int { state.order.count - firstPosition }

    /// Where the current track is in play order. Found once per state, since every row reads
    /// it and the search is as long as the queue.
    private(set) var currentPosition: Int?

    private var firstPosition: Int { currentPosition ?? 0 }

    /// The current track's row.
    var currentRow: Int? { currentPosition.map { _ in 0 } }

    /// The engine's position in play order of the track at `row`.
    func position(ofRow row: Int) -> Int { row + firstPosition }

    /// Where a drag proposed for above `row` drops: below the current track, since a track
    /// moved before it counts as played and leaves the list.
    func dropRow(_ row: Int) -> Int { max(row, currentRow.map { $0 + 1 } ?? 0) }

    func positions(ofRows rows: IndexSet) -> IndexSet {
        IndexSet(rows.map(position(ofRow:)))
    }

    /// The track at `row`.
    public func item(at row: Int) -> QueueItem {
        let url = state.queue[state.order[position(ofRow: row)]]
        if let item = described[url.path] { return item }
        if described.count >= Self.lookupCapacity { described = [:] }
        let item: QueueItem
        do {
            item = QueueItem(url: url, row: try lookup(url.path))
        } catch {
            logger.error("couldn't read the library's row for \(url.path): \(error)")
            item = QueueItem(url: url, row: nil)
        }
        described[url.path] = item
        return item
    }

    /// "12 tracks". No total time: that would look up every track of a queue that can hold the
    /// whole library.
    public var summary: String { "\(count) track\(count == 1 ? "" : "s")" }
}

/// One queue row as the panel shows it.
public struct QueueItem: Equatable, Sendable {
    public var title: String
    /// "Artist — Album", or the folder for a file the library doesn't know.
    public var detail: String
    public var durationSeconds: Double?

    init(url: URL, row: TrackRow?) {
        guard let row else {
            title = url.deletingPathExtension().lastPathComponent
            detail = url.deletingLastPathComponent().path
            durationSeconds = nil
            return
        }
        title = row.title
        detail = [row.artist, row.album].compactMap { $0 }.joined(separator: " — ")
        durationSeconds = row.durationSeconds
    }
}
