/// A path with stats whose file left the library and that no scan matched with a new path, for
/// the user to resolve in Lost Stats (ADR 0026).
public struct LostFile: Equatable, Sendable {
    /// The path's ID, which holds its stats.
    public var id: Int64
    public var path: String
    /// The tracks with no stats of their own whose codec, sample rate and length match it, in
    /// ID order: the first `lostCandidatesListed` of them.
    public var candidates: [Int64]
    /// How many tracks match it, listed or not.
    public var matching: Int
}
