/// What the rescan question says before a rebuild drops parts that a rescan refills
/// (ADR 0136): why each part changed, in the part's own words, and what the rescan does and
/// keeps.
public struct RescanNotice: Equatable, Sendable {
    /// The parts the rebuild drops that a rescan refills, for their own reasons.
    let parts: [SchemaPart]
    /// How the rebuild makes albums, when a change of Separate Releases is a reason for it
    /// (ADR 0143); nil when it isn't.
    let separateReleases: Bool?

    /// Nil when no part of `parts` is refilled by a rescan and `separateReleases` is nil, so
    /// there is nothing to ask.
    init?(parts: [SchemaPart], separateReleases: Bool? = nil) {
        let refilled = SchemaPart.allCases.filter { parts.contains($0) && $0.rescanWhy != nil }
        guard !refilled.isEmpty || separateReleases != nil else { return nil }
        self.parts = refilled
        self.separateReleases = separateReleases
    }

    /// The question for turning Separate Releases on or off while the app runs.
    public init(separatingReleases on: Bool) {
        parts = []
        separateReleases = on
    }

    public var title: String { "Rescan the Library?" }

    public var text: String {
        let direction = separateReleases.map {
            $0
                ? "Albums are made of each Discogs release, so a reissue tagged with the"
                    + " original's title is an album of its own."
                : "Albums are made of title and artist again, so releases that share them merge."
        }
        return
            ([direction].compactMap { $0 } + parts.compactMap(\.rescanWhy)
            + ["Every file is read again. Plays, ratings and playlists stay."])
            .joined(separator: "\n\n")
    }
}
