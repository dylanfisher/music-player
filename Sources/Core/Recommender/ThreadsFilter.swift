import Foundation
import Settings

/// The Threads panel's four filters (ADR 0209), kept in the settings. They're the panel's,
/// not the seed's, so every seed shows with the same ones.
package struct ThreadsFilter: Equatable, Sendable {
    /// Hides every `artist` thread.
    package var otherArtistsOnly: Bool
    /// The kinds of the other threads not listed.
    package var hiddenKinds: Set<ThreadsKind>
    package var played: ThreadsPlayed
    /// Applies only while the seed has a year.
    package var years: ThreadsYears

    package init(
        otherArtistsOnly: Bool, hiddenKinds: Set<ThreadsKind>, played: ThreadsPlayed,
        years: ThreadsYears
    ) {
        self.otherArtistsOnly = otherArtistsOnly
        self.hiddenKinds = hiddenKinds
        self.played = played
        self.years = years
    }

    /// The filters as `settings` have them.
    @MainActor
    package init(_ settings: ConfigStore<AppSettings>) {
        self.init(
            otherArtistsOnly: settings[\.threadsOtherArtistsOnly],
            hiddenKinds: Set(settings[\.threadsHiddenKinds]), played: settings[\.threadsPlayed],
            years: settings[\.threadsYears])
    }

    /// The settings' defaults: every thread and album shown.
    package static var defaults: ThreadsFilter {
        let schema = AppSettings()
        return ThreadsFilter(
            otherArtistsOnly: schema.threadsOtherArtistsOnly.defaultValue,
            hiddenKinds: Set(schema.threadsHiddenKinds.defaultValue),
            played: schema.threadsPlayed.defaultValue, years: schema.threadsYears.defaultValue)
    }

    /// Writes the filters to `settings`, the hidden kinds in the pull-down's order.
    @MainActor
    package func save(to settings: ConfigStore<AppSettings>) throws {
        try settings.set(\.threadsOtherArtistsOnly, to: otherArtistsOnly)
        try settings.set(
            \.threadsHiddenKinds, to: ThreadsKind.allCases.filter(hiddenKinds.contains))
        try settings.set(\.threadsPlayed, to: played)
        try settings.set(\.threadsYears, to: years)
    }

    /// Whether a thread of `kind` is listed.
    func shows(_ kind: RediscoverDay.Thread.Kind) -> Bool {
        guard let choice = kind.choice else { return !otherArtistsOnly }
        return !hiddenKinds.contains(choice)
    }

    /// Whether `album` passes Played at `now` and Years beside the seed's year `seedYear`.
    func passes(_ album: RediscoverDay.Album, seedYear: Int?, now: Date) -> Bool {
        switch played {
        case .anyTime: break
        case .neverPlayed: guard album.plays == 0 else { return false }
        case .notInAYear:
            let yearAgo = now.timeIntervalSince1970 - Self.yearSeconds
            if album.plays > 0, let last = album.lastPlayed, Double(last) >= yearAgo {
                return false
            }
        }
        guard let span = years.span, let seedYear else { return true }
        guard let year = album.year else { return false }
        return abs(year - seedYear) <= span
    }

    /// Not in a Year's span: 365 days.
    static let yearSeconds: TimeInterval = 365 * 86_400
}

extension RediscoverDay.Thread.Kind {
    /// The Kinds pull-down's item for this kind; nil for `artist`, which isn't one.
    var choice: ThreadsKind? { ThreadsKind(rawValue: rawValue) }
}

/// What Threads lists of a reply under a filter: the threads of the kinds shown, each with its
/// albums that pass, and All's albums.
package struct ShownThreads: Equatable, Sendable {
    package struct Thread: Equatable, Sendable {
        /// Its place among the reply's threads.
        package var place: Int
        package var thread: RediscoverDay.Thread
        /// The `id`s of its albums the filters pass, in the thread's order; empty for a thread
        /// the filters emptied.
        package var ids: [String]
    }

    package var threads: [Thread]
    /// The `id`s of the albums the filters pass in one of `threads` or more, or in no thread
    /// of the reply, in the reply's order.
    package var albums: [String]
}

extension AlbumThreads {
    /// What the threads list under `filter` at `now`. An album the filters leave out is in no
    /// thread and not in All, nor is one whose every thread is hidden, so with Other Artists
    /// Only All has no album that only the seed artist's thread holds.
    package func shown(by filter: ThreadsFilter, now: Date) -> ShownThreads {
        let passing = Set(
            albums.filter { filter.passes($0, seedYear: seed.year, now: now) }.map(\.id))
        let threads = self.threads.enumerated().filter { filter.shows($0.element.kind) }.map {
            ShownThreads.Thread(
                place: $0.offset, thread: $0.element, ids: $0.element.ids.filter(passing.contains))
        }
        let inShown = Set(threads.flatMap(\.ids))
        let inAny = Set(self.threads.flatMap(\.ids))
        return ShownThreads(
            threads: threads,
            albums: albums.map(\.id).filter {
                inShown.contains($0) || (passing.contains($0) && !inAny.contains($0))
            })
    }
}
