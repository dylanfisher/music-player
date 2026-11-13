import Library

/// The edits to the tracks' stats from the window and from playback. Each refreshes what it
/// changed.
extension BrowserModel {
    /// Rates the tracks `trackIDs`; 0 stars clears their rating.
    public func rate(_ trackIDs: [Int64], stars: Int) async throws {
        try await reader.setRating(stars, trackIDs: trackIDs)
        await refreshEdited()
    }

    /// Rates the tracks at `paths`, returning the ids of those the index has.
    func setRating(_ stars: Int, paths: [String]) async throws -> [Int64] {
        let rated = try await reader.setRating(stars, paths: paths)
        await refreshEdited()
        return rated
    }

    func toggle(_ opinion: TrackOpinion, _ trackIDs: [Int64]) async throws {
        try await reader.toggle(opinion, trackIDs: trackIDs)
        await refreshEdited()
    }

    public func recordPlay(_ path: String, at seconds: Double) async throws {
        try await reader.recordPlay(path, at: seconds)
        await refreshEdited()
    }

    /// Sets the play count of the tracks at `paths` by hand (ADR 0162).
    func setPlayCount(_ count: Int, paths: [String]) async throws {
        try await reader.setPlayCount(count, paths: paths)
        await refreshEdited()
    }

    public func recordSkip(_ path: String) async throws {
        try await reader.recordSkip(path)
        await refreshEdited()
    }
}
