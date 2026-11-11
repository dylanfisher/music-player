import Foundation

/// How far a batch write has got, so a slow save on a NAS doesn't look stuck (ADR 0108). A
/// file counts as read once it's read and planned, and as written once it's written and read
/// back, left alone, or failed; files written in place are read a chunk ahead of their writes.
public struct TagWriteProgress: Equatable, Sendable {
    public var total: Int
    public var read = 0
    public var written = 0

    init(total: Int) { self.total = total }

    /// From 0 to 1, reading and writing each counting for half.
    public var fraction: Double {
        total == 0 ? 1 : Double(read + written) / Double(2 * total)
    }

    /// The batches `parts` as one batch of `total` files, the files of a batch that hasn't
    /// reported yet counting as neither read nor written.
    public static func combined(_ parts: [TagWriteProgress], total: Int) -> TagWriteProgress {
        var all = TagWriteProgress(total: total)
        all.read = parts.map(\.read).reduce(0, +)
        all.written = parts.map(\.written).reduce(0, +)
        return all
    }
}

/// A batch's progress, counted from the threads that write its files, each change handed to
/// `report` in order.
/// `progress` is guarded by `lock`, which is held while `report` runs, so values arrive in
/// order.
final class WriteProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: TagWriteProgress
    private let report: @Sendable (TagWriteProgress) -> Void

    init(total: Int, report: @escaping @Sendable (TagWriteProgress) -> Void) {
        progress = TagWriteProgress(total: total)
        self.report = report
    }

    func read() { update { $0.read += 1 } }
    func written() { update { $0.written += 1 } }

    private func update(_ change: (inout TagWriteProgress) -> Void) {
        lock.withLock {
            change(&progress)
            report(progress)
        }
    }
}
