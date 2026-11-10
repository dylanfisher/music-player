/// How far the renames of an organize have got (ADR 0175): the files reached of the plan's
/// moves, and the file being renamed now, nil once the renames are done and the folders they
/// left are being tidied.
public struct OrganizeProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var current: String?

    init(done: Int, total: Int, current: String?) {
        self.done = done
        self.total = total
        self.current = current
    }

    /// The files not yet reached.
    public var left: Int { total - done }
}
