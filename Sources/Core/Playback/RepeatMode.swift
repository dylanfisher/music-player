public enum RepeatMode: String, CaseIterable, Sendable {
    case off
    /// The current track again and again.
    case one
    /// The whole queue, from the start once it ends.
    case all
}
