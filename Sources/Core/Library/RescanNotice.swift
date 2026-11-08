/// What the rescan question says before a rebuild drops parts that a rescan refills
/// (ADR 0136): why each part changed, in the part's own words, and what the rescan does and
/// keeps.
public struct RescanNotice: Equatable, Sendable {
    /// The parts the rebuild drops that a rescan refills.
    let parts: [SchemaPart]

    /// Nil when no part of `parts` is refilled by a rescan, so there is nothing to ask.
    init?(parts: [SchemaPart]) {
        let refilled = SchemaPart.allCases.filter { parts.contains($0) && $0.rescanWhy != nil }
        guard !refilled.isEmpty else { return nil }
        self.parts = refilled
    }

    public var title: String { "The library needs a rescan" }

    public var text: String {
        (parts.compactMap(\.rescanWhy)
            + ["Every file is read again. Plays, ratings and playlists stay."])
            .joined(separator: "\n\n")
    }
}
