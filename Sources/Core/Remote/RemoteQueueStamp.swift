import Foundation
import Playback

/// The queue's change stamp and the time this Mac last started playing, kept from each playback
/// update, for the remote's state (ADR 0214): the page fetches the queue again only when the
/// stamp moves, and chooses among Macs playing by the newest start.
public struct RemoteQueueStamp: Sendable {
    private(set) var stamp = 0
    private(set) var lastPlayedAt: Double?
    private var queue: [URL] = []
    private var order: [Int] = []
    private var playing = false

    public init() {}

    /// Notes `state`, as it was at `time` in seconds since 1970.
    public mutating func note(_ state: PlaybackState, at time: Double) {
        if state.queue != queue || state.order != order {
            stamp += 1
            queue = state.queue
            order = state.order
        }
        let now = state.status == .playing
        if now && !playing { lastPlayedAt = time }
        playing = now
    }
}

extension RemoteState {
    /// The state from playback as it is, `position` read at `readAt`. A position that isn't a
    /// finite number is left out, since JSON can't hold it.
    public init(
        identity: RemoteService.Identity, playback: PlaybackState, position: Double?,
        readAt: Double, track: Track?, queue: RemoteQueueStamp, volumeDecibels: Double?,
        output: Output?, receiver: Receiver?
    ) {
        let state: Playing =
            switch playback.status {
            case .stopped: .stopped
            case .playing: .playing
            case .paused: .paused
            }
        self.init(
            instance: identity.id, name: identity.name, state: state, track: track,
            positionSeconds: state == .stopped ? nil : position.flatMap { $0.isFinite ? $0 : nil },
            positionReadAt: readAt, queueStamp: queue.stamp, queueLength: playback.queue.count,
            queuePosition: playback.currentIndex.flatMap { index in
                playback.order.firstIndex(of: index).map { $0 + 1 }
            }, shuffle: playback.shuffle, repeatMode: playback.repeatMode.rawValue,
            volumeDecibels: volumeDecibels.flatMap { $0.isFinite ? $0 : nil }, output: output,
            receiver: receiver, lastPlayedAt: queue.lastPlayedAt)
    }
}
