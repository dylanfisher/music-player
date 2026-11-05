import Settings

/// Undo Selection and Redo Selection's steps, oldest first: the track table's selections, each
/// with the window it was made in, and where undo and redo are in them (ADR 0091). Separate
/// from Back and Forward, and playback is no part of it.
struct SelectionHistory: Equatable, Sendable {
    /// What changed the selection, which decides whether it joins the current step.
    enum Cause: Equatable, Sendable {
        /// A click, Show Current Track, a reveal or any other jump: a step of its own.
        case jump
        /// A selection command's key, such as ↓ or ⇧↓: consecutive ones in one source are one
        /// step.
        case key
        /// A reload that kept or dropped selected tracks: the next change takes its place.
        case reload
    }

    /// The most steps kept; the oldest go first.
    static let limit = 100

    private(set) var steps: [WindowPlace] = []
    /// The current step; nil before the first selection.
    private(set) var position: Int?
    /// What made the current step, while the next change may still join it.
    private var joinable: Cause?

    /// Records `place`, the window just after its selection changed. An empty selection, or
    /// the current step's selection in its source, adds nothing. A new step drops the steps
    /// redo would have gone to.
    mutating func record(_ place: WindowPlace, cause: Cause) {
        guard !place.selection.isEmpty else { return }
        if let position {
            let current = steps[position]
            guard !Self.place(place, shows: current) else { return }
            let joins =
                joinable == .reload
                || (joinable == .key && cause == .key
                    && current.filter.source == place.filter.source)
            if joins {
                steps[position] = place
                joinable = cause == .jump ? nil : cause
                return
            }
            // The scroll the current selection was left at, while the list is the same.
            if current.filter == place.filter { steps[position].scroll = place.scroll }
        }
        steps = Array(steps.prefix((position ?? -1) + 1)) + [place]
        if steps.count > Self.limit { steps.removeFirst(steps.count - Self.limit) }
        position = steps.count - 1
        joinable = cause == .jump ? nil : cause
    }

    /// Whether undo has a step to show from the window `place`.
    func canUndo(from place: WindowPlace) -> Bool {
        guard let position else { return false }
        return position > 0 || !Self.place(place, shows: steps[position])
    }

    var canRedo: Bool { position.map { $0 < steps.count - 1 } ?? false }

    /// The step undo shows from the window `place`: the current one when the window has moved
    /// off it, such as to another source, else the one before, leaving the current one as
    /// `place` has it so redo comes back to it. Nil when there's none.
    mutating func undo(from place: WindowPlace) -> WindowPlace? {
        guard let current = position else { return nil }
        joinable = nil
        guard Self.place(place, shows: steps[current]) else { return steps[current] }
        guard current > 0 else { return nil }
        steps[current] = place
        position = current - 1
        return steps[current - 1]
    }

    /// The step after the current one, leaving the current one as `place` has it when the
    /// window still shows it. Nil at the last step.
    mutating func redo(from place: WindowPlace) -> WindowPlace? {
        guard let current = position, current < steps.count - 1 else { return nil }
        joinable = nil
        if Self.place(place, shows: steps[current]) { steps[current] = place }
        position = current + 1
        return steps[current + 1]
    }

    /// Forgets the steps whose source `gone` picks, such as deleted playlists, and the repeats
    /// that leaves, keeping the place at the nearest step before it that stays.
    mutating func remove(_ gone: (BrowserSource?) -> Bool) {
        guard let position else { return }
        var kept: [WindowPlace] = []
        var place: Int?
        for (index, step) in steps.enumerated() where !gone(step.filter.source) {
            if kept.last.map({ Self.place(step, shows: $0) }) != true { kept.append(step) }
            if index <= position { place = kept.count - 1 }
        }
        steps = kept
        self.position = kept.isEmpty ? nil : place ?? 0
        joinable = nil
    }

    /// Whether `place` shows `step`: the same selection in the same source.
    private static func place(_ place: WindowPlace, shows step: WindowPlace) -> Bool {
        place.selection == step.selection && place.filter.source == step.filter.source
    }
}
