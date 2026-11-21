/// An edit to the queue by positions in play order, as the web remote asks for it.
public enum QueueEdit: Equatable, Sendable {
    /// The track at the first position to just before the second, counted before the move.
    case move(Int, before: Int)
    case remove(Int)
}
