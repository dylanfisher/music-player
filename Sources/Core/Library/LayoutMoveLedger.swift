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
public func carryLayoutMoves(
    databaseURL: URL,
    carry: @Sendable ([(from: String, to: String)]) async throws -> MoveListImport
) async -> LayoutCarry {
    var result = LayoutCarry()
    let found = await blockingFileWork {
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
    let forgotten = await blockingFileWork {
        Result { try LibraryIndex(at: databaseURL).forgetLayoutMoves(lines.map(\.from)) }
    }
    if case .failure(let error) = forgotten {
        result.problems.append("couldn't drop the carried moves, which are carried again: \(error)")
    }
    return result
}

private func notFollowed(_ move: TrackMove, _ reason: String) -> String {
    "the stats of \(move.from) didn't follow it to \(move.to): \(reason)"
}
