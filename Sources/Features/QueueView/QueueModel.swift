import Foundation
import Library
import Log
import Playback

private let logger = moduleLogger()

/// The queue panel's rows: the engine's queue in play order, each described from the library.
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

    public func apply(_ state: PlaybackState) {
        self.state = state
    }

    public var count: Int { state.order.count }

    /// Where the current track is in play order.
    public var currentPosition: Int? {
        state.currentIndex.flatMap { state.order.firstIndex(of: $0) }
    }

    /// The track at `position` in play order.
    public func item(at position: Int) -> QueueItem {
        let url = state.queue[state.order[position]]
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
