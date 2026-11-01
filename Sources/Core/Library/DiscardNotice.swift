/// What one rebuild of the stats discarded, as a line for the owner (ADR 0022).
public struct DiscardNotice: Equatable, Sendable {
    /// Its row, for forgetting it once shown.
    public var id: Int64
    public var text: String
}
