import Foundation
import Metadata

extension LibraryIndex {
    /// Records `moves` before their files are renamed, so their stats can follow them however
    /// the rename and the carry end (ADR 0164). A move recorded again replaces the one before.
    func recordLayoutMoves(_ moves: [TrackMove]) throws {
        try database.transaction {
            for move in moves {
                try statement(
                    "INSERT OR REPLACE INTO \(layoutMovesTable) (old_path, new_path) VALUES (?, ?)"
                ).run(move.from, move.to)
            }
        }
    }

    /// Drops the moves of the files at `paths`, their old paths: never renamed, or carried.
    func forgetLayoutMoves(_ paths: [String]) throws {
        try database.transaction {
            for path in paths {
                try statement("DELETE FROM \(layoutMovesTable) WHERE old_path = ?").run(path)
            }
        }
    }

    /// The moves recorded and not yet forgotten, by old path.
    func layoutMoves() throws -> [TrackMove] {
        try statement("SELECT old_path, new_path FROM \(layoutMovesTable) ORDER BY old_path")
            .map { row in TrackMove(from: try row.text(0), to: try row.text(1)) }
    }
}

/// What carrying the organized files' stats did.
public struct LayoutCarry: Equatable, Sendable {
    /// The moves whose stats followed their files, or had already.
    public var carried: [TrackMove] = []
    /// One line for each move whose stats didn't follow, saying which and why.
    public var problems: [String] = []

    public init(carried: [TrackMove] = [], problems: [String] = []) {
        self.carried = carried
        self.problems = problems
    }
}

/// Gives the stats of every file Keep Files Organized renamed, as the index at `databaseURL`
/// recorded them, to its new path through `carry`, the move list (ADR 0164). A move whose file
/// is still at its old path and not at its new one never happened, and is dropped. A carry
/// that fails keeps every move it was given, which the next carry, at the next organize or
/// launch, tries again; a carry that runs drops them all, and lists those it couldn't move.
/// The ledger is read and written through `serially`, which runs its work on the queue that
/// `moveToLayout` runs on, the tag writes': run anywhere else, a read between an organize's
/// record of its moves and its renames would find the files at their old paths and drop the
/// moves as never made.
func carryLayoutMoves(
    databaseURL: URL,
    serially: @Sendable (@escaping @Sendable () -> Void) async -> Void,
    carry: @Sendable ([(from: String, to: String)]) async throws -> MoveListImport
) async -> LayoutCarry {
    var result = LayoutCarry()
    let found = await run(serially) {
        () -> Result<(lines: [TrackMove], undone: [String], lost: [TrackMove]), any Error> in
        Result {
            let index = try LibraryIndex(at: databaseURL)
            var lines: [TrackMove] = []
            var undone: [String] = []
            var lost: [TrackMove] = []
            for move in try index.layoutMoves() {
                switch (pathExists(move.from), pathExists(move.to)) {
                case (false, true): lines.append(move)
                case (true, false): undone.append(move.from)
                default: lost.append(move)
                }
            }
            try index.forgetLayoutMoves(undone + lost.map(\.from))
            return (lines, undone, lost)
        }
    }
    let lines: [TrackMove]
    switch found {
    case .success(let moves):
        lines = moves.lines
        result.problems += moves.lost.map {
            notFollowed(
                $0,
                pathExists($0.from)
                    ? "a file is at both paths" : "neither path has a file")
        }
    case .failure(let error):
        return LayoutCarry(problems: ["couldn't read the moves whose stats to carry: \(error)"])
    }
    guard !lines.isEmpty else { return result }
    let imported: MoveListImport
    do {
        imported = try await carry(lines.map { ($0.from, $0.to) })
    } catch {
        result.problems += lines.map {
            notFollowed($0, "\(error); they follow it at the next launch")
        }
        return result
    }
    let failed = Dictionary(
        imported.problems.map { ($0.line, $0.reason) }, uniquingKeysWith: { one, _ in one })
    for (offset, move) in lines.enumerated() {
        if let reason = failed[offset + 1] {
            result.problems.append(notFollowed(move, reason))
        } else {
            result.carried.append(move)
        }
    }
    let forgotten = await run(serially) {
        Result { try LibraryIndex(at: databaseURL).forgetLayoutMoves(lines.map(\.from)) }
    }
    if case .failure(let error) = forgotten {
        result.problems.append("couldn't drop the carried moves, which are carried again: \(error)")
    }
    return result
}

/// Runs `carryLayoutMoves` one carry at a time, each after the one before has dropped its
/// moves: two at once would both read the moves, and the second, finding them carried, would
/// call each of a track with no stats one whose old path isn't in the library.
@MainActor
public final class LayoutCarrier {
    private var last: Task<Void, Never>?

    public init() {}

    /// What `carryLayoutMoves` with these arguments did, once every carry before it is done.
    public func carry(
        databaseURL: URL,
        serially: @escaping @Sendable (@escaping @Sendable () -> Void) async -> Void,
        carry: @escaping @Sendable ([(from: String, to: String)]) async throws -> MoveListImport
    ) async -> LayoutCarry {
        let previous = last
        let next = Task {
            await previous?.value
            return await carryLayoutMoves(
                databaseURL: databaseURL, serially: serially, carry: carry)
        }
        last = Task { _ = await next.value }
        return await next.value
    }
}

/// What `work` returns, run through `serially`.
private func run<T: Sendable>(
    _ serially: @Sendable (@escaping @Sendable () -> Void) async -> Void,
    _ work: @escaping @Sendable () -> T
) async -> T {
    let box = Box<T>()
    await serially { box.value = work() }
    guard let value = box.value else { preconditionFailure("serially returned without running") }
    return value
}

/// One value handed from the queue `serially` runs on.
private final class Box<T: Sendable>: @unchecked Sendable {
    // `stored` is guarded by `lock`.
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func notFollowed(_ move: TrackMove, _ reason: String) -> String {
    "the stats of \(move.from) didn't follow it to \(move.to): \(reason)"
}
