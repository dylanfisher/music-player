/// A path with stats whose file left the library and that no scan matched with a new path, for
/// the user to resolve in Lost Stats (ADR 0026).
struct LostFile: Equatable, Sendable {
    /// The path's ID, which holds its stats.
    var id: Int64
    var path: String
    /// The tracks with no stats of their own whose codec, sample rate and length match it, in
    /// ID order.
    var candidates: [Int64]
}
