import DisplayText
import Foundation

/// How many lines of a move list one transaction applies, so a long list doesn't hold the
/// database from the window's edits for long.
let moveListBatchLines = 1000

extension LibraryIndex {
    /// Import Moves… (ADR 0026): gives each old path in the move list at `list` the new path
    /// its line names, as a scan's match or another machine's `move` does, and logs the move
    /// for the other machines. Reads only the list, and asks the file system only whether each
    /// new file, and an old one the index still has, exists. A line that can't move anything is
    /// a problem and the rest go on.
    func importMoves(from list: URL) throws -> MoveListImport {
        let parsed = MoveList(try Data(contentsOf: list))
        var result = MoveListImport(problems: parsed.problems)
        var removedFiles = false
        for start in stride(from: 0, to: parsed.lines.count, by: moveListBatchLines) {
            let batch = parsed.lines[start..<min(start + moveListBatchLines, parsed.lines.count)]
            // The file system is asked before the transaction, which a slow share would hold.
            let checked = try batch.map { line in (line, try check(line)) }
            try database.transaction {
                let roots = try syncRoots()
                for (line, check) in checked {
                    switch check {
                    case .problem(let reason):
                        result.problems.append(MoveListProblem(line: line.number, reason: reason))
                    case .ready(let oldFileGone):
                        if let reason = try applyMove(
                            line, oldFileGone: oldFileGone, roots, &result, &removedFiles)
                        {
                            result.problems.append(
                                MoveListProblem(line: line.number, reason: reason))
                        }
                    }
                }
            }
        }
        if removedFiles { try deleteOrphans() }
        result.problems.sort { $0.line < $1.line }
        return result
    }

    private enum MoveListCheck {
        /// `oldFileGone` is true when the index had a file at the old path that's no longer on
        /// disk, nil when it had none.
        case ready(oldFileGone: Bool?)
        case problem(String)
    }

    /// Whether `line`'s new file is on disk, and an old file the index still lists gone.
    private func check(_ line: MoveList.Line) throws -> MoveListCheck {
        guard FileManager.default.fileExists(atPath: line.to) else {
            return .problem("the new file \(terminalSafe(line.to)) isn't there")
        }
        let nfc = line.from.precomposedStringWithCanonicalMapping
        guard let old = try existingPathID(nfc), try hasFile(old) else {
            return .ready(oldFileGone: nil)
        }
        return .ready(oldFileGone: !FileManager.default.fileExists(atPath: line.from))
    }

    /// Whether the index has a file for the path `id`.
    func hasFile(_ id: Int64) throws -> Bool {
        try !statement("SELECT 1 FROM files WHERE id = ?").map(id, row: { _ in () }).isEmpty
    }

    /// Moves `line`'s old path to its new one, counting it in `result`; returns why it didn't.
    /// Call inside a transaction.
    private func applyMove(
        _ line: MoveList.Line, oldFileGone: Bool?, _ roots: SyncRoots,
        _ result: inout MoveListImport, _ removedFiles: inout Bool
    ) throws -> String? {
        let from = line.from.precomposedStringWithCanonicalMapping
        let to = line.to.precomposedStringWithCanonicalMapping
        guard let old = try existingPathID(from) else {
            // A scan matched the move, or an import of this list did: the new path has the stats.
            guard let new = try existingPathID(to), try pathHasStats(new) else {
                return "the old path \(terminalSafe(line.from)) isn't in the library"
            }
            result.alreadyDone += 1
            return nil
        }
        if try hasFile(old) {
            // No scan has run since the file went. The index lets it go as a scan would, so the
            // next scan finds nothing gone.
            switch oldFileGone {
            case true?:
                try deleteFile(old)
                removedFiles = true
            case false?:
                return "the old file \(terminalSafe(line.from)) is still there"
            case nil:
                return "a scan added the old file \(terminalSafe(line.from)) during the import;"
                    + " import the list again"
            }
        }
        if try takeMove(old, to: to) { result.merged += 1 } else { result.moved += 1 }
        try logMove(from: from, to: to, roots)
        return nil
    }
}
