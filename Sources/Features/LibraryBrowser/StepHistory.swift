import Foundation
import Library
import Playback
import Settings

/// The window as a step of the history keeps it: what the browser showed, the selected tracks,
/// and the first visible track with how far it sat from the top of the list.
struct WindowPlace: Equatable, Sendable {
    struct Scroll: Equatable, Sendable {
        var id: Int64
        var offset: CGFloat
    }

    var filter: TrackFilter
    var selection: Set<Int64> = []
    var scroll: Scroll?
}

/// Back and Forward's steps, oldest first: each source the sidebar showed and each play from the
/// browser, and where Back and Forward are in them (ADR 0090).
///
/// Each step keeps the window as it was when last left, so Back over a step shows the window
/// as it was just before that step, and Forward as Back left it. A play also keeps the
/// playback on both sides of it: Back puts back what it replaced, Forward what it played.
struct StepHistory: Equatable, Sendable {
    struct Play: Equatable, Sendable {
        /// What played when this play replaced it.
        var replaced: PlaybackSpot
        /// What this play started, and once Back has undone it, where it had got to.
        var played: PlaybackSpot
    }

    struct Step: Equatable, Sendable {
        var window: WindowPlace
        /// Nil for a place.
        var play: Play?
    }

    /// Where Back or Forward went: the window to show, and the playback to put back when the
    /// step it crossed is a play.
    struct Move: Equatable, Sendable {
        var window: WindowPlace
        var playback: PlaybackSpot?
    }

    private(set) var steps: [Step]
    private(set) var position = 0

    init(start: WindowPlace) {
        steps = [Step(window: start)]
    }

    var canGoBack: Bool { position > 0 }
    var canGoForward: Bool { position < steps.count - 1 }

    /// A source shown, `window` as it shows first; `leaving` is the window before it. The source
    /// already shown adds nothing.
    mutating func visit(_ window: WindowPlace, leaving: WindowPlace) {
        guard window.filter.source != steps[position].window.filter.source else { return }
        add(Step(window: window), leaving: leaving)
    }

    /// A play started from `window`, replacing `replaced`.
    mutating func play(
        _ played: PlaybackSpot, replacing replaced: PlaybackSpot, from window: WindowPlace
    ) {
        add(Step(window: window, play: Play(replaced: replaced, played: played)), leaving: window)
    }

    /// Drops the steps Forward would have gone to.
    private mutating func add(_ step: Step, leaving window: WindowPlace) {
        steps[position].window = window
        steps = Array(steps[...position]) + [step]
        position += 1
    }

    /// The step before, leaving the current one with `window` and, when it's a play, with
    /// `playing` as where it had got to. Nil at the start.
    mutating func back(leaving window: WindowPlace, playing: PlaybackSpot?) -> Move? {
        guard canGoBack else { return nil }
        let crossed = position
        steps[crossed].window = window
        if let playing { steps[crossed].play?.played = playing }
        position -= 1
        return Move(window: steps[position].window, playback: steps[crossed].play?.replaced)
    }

    /// The step after, leaving the current one with `window`; when the step after is a play,
    /// `playing` is what it replaces this time.
    mutating func forward(leaving window: WindowPlace, playing: PlaybackSpot?) -> Move? {
        guard canGoForward else { return nil }
        steps[position].window = window
        position += 1
        if let playing { steps[position].play?.replaced = playing }
        return Move(window: steps[position].window, playback: steps[position].play?.played)
    }

    /// Forgets the places whose source `gone` picks, such as deleted playlists, and the repeats
    /// that leaves, keeping the place at the nearest step before it that stays. A play there
    /// stays a step, its window showing the whole library.
    mutating func remove(_ gone: (BrowserSource?) -> Bool) {
        var kept: [Step] = []
        var place = 0
        for (index, step) in steps.enumerated() {
            var step = step
            if gone(step.window.filter.source) {
                guard step.play != nil else { continue }
                step.window = WindowPlace(
                    filter: TrackFilter(groupByAlbumArtist: step.window.filter.groupByAlbumArtist))
            }
            let repeats =
                step.play == nil
                && kept.last.map { $0.window.filter.source == step.window.filter.source } == true
            if !repeats { kept.append(step) }
            if index <= position { place = kept.count - 1 }
        }
        steps = kept.isEmpty ? [Step(window: WindowPlace(filter: TrackFilter()))] : kept
        position = place
    }
}
