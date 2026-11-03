import Foundation

/// Turns the engine's updates into plays and skips. A track counts as played once it has played,
/// not paused, for `playedFraction` of its length, or `unknownLengthSeconds` when its length
/// isn't known; it counts as skipped when another track starts before that. Stopping is
/// neither. Seeking doesn't count toward either, since the time is what was heard.
///
/// It reads only the updates the engine already sends, and the caller's clock, so the IO proc
/// is never involved. Nothing polls: `deadline` says when the current track would count, and the
/// caller calls `tick` then.
public struct PlayCounter: Sendable {
    public enum Event: Equatable, Sendable {
        case played(URL)
        case skipped(URL)
    }

    /// What a track of unknown length needs to play to count.
    static let unknownLengthSeconds = 240.0
    /// The wall-clock time from a track's start to its end can come out a little short of its
    /// length, so a track that reached its end counts this close to its share.
    static let endSlackSeconds = 1.0

    /// The share of a track's length that has to play for it to count, from 0 to 1. A change
    /// applies from the next track.
    var playedFraction: Double

    /// The track that started last and hasn't been counted or left.
    private struct Listen {
        var url: URL
        var neededSeconds: Double
        var heardSeconds = 0.0
        /// When the current stretch of playing began; nil while paused or stopped.
        var playingSince: Date?
        var counted = false
        /// The track played to its end, so moving on isn't a skip.
        var ended = false

        func heard(at now: Date) -> Double {
            heardSeconds + (playingSince.map { now.timeIntervalSince($0) } ?? 0)
        }
    }

    private var listen: Listen?

    init(playedFraction: Double) {
        self.playedFraction = playedFraction
    }

    /// When the current track counts as played if it keeps playing; nil when nothing is
    /// playing or it has already counted.
    public var deadline: Date? {
        guard let listen, !listen.counted, let since = listen.playingSince else { return nil }
        return since.addingTimeInterval(listen.neededSeconds - listen.heardSeconds)
    }

    public mutating func handle(_ update: PlaybackUpdate, at now: Date) -> [Event] {
        var events: [Event] = []
        if case .trackStarted(let index) = update.event {
            if var previous = listen {
                events += count(&previous, at: now)
                if !previous.counted, !previous.ended { events.append(.skipped(previous.url)) }
            }
            let duration = update.state.durationSeconds ?? 0
            listen = Listen(
                url: update.state.queue[index],
                neededSeconds: duration > 0
                    ? duration * playedFraction : Self.unknownLengthSeconds)
        }
        if case .trackEnded = update.event { listen?.ended = true }
        guard var current = listen else { return events }
        if update.event == .stopped {
            // Stopping ends the listen without a skip; a play it reached still counts.
            events += count(&current, at: now)
            listen = nil
            return events
        }
        events += count(&current, at: now)
        let playing = update.state.status == .playing
        if playing, current.playingSince == nil {
            current.playingSince = now
        } else if !playing, let since = current.playingSince {
            current.heardSeconds += now.timeIntervalSince(since)
            current.playingSince = nil
        }
        listen = current
        return events
    }

    /// Counts the current track if it has now played long enough.
    mutating func tick(at now: Date) -> [Event] {
        guard var current = listen else { return [] }
        let events = count(&current, at: now)
        listen = current
        return events
    }

    private func count(_ listen: inout Listen, at now: Date) -> [Event] {
        // A tick at `deadline` can come out a hair short in floating point.
        let slack = listen.ended ? Self.endSlackSeconds : 0.001
        guard !listen.counted, listen.heard(at: now) >= listen.neededSeconds - slack else {
            return []
        }
        listen.counted = true
        return [.played(listen.url)]
    }
}
