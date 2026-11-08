import DisplayText
import Foundation

/// A move list (ADR 0026): one line a file, its old absolute path, a tab and its new one, and
/// a newline, as a conversion script writes it once the new file is in place and the old one
/// gone.
struct MoveList {
    struct Line {
        /// From 1, as an editor counts.
        var number: Int
        var from: String
        var to: String
    }

    var lines: [Line] = []
    /// Each line that doesn't parse.
    var problems: [MoveListProblem] = []

    /// The list of `moves`, each an old absolute path and its new one, as its lines would be
    /// written; a path holding a tab or a newline is a problem, as in a list read from disk.
    init(moves: [(from: String, to: String)]) {
        self.init(Data(moves.map { $0.from + "\t" + $0.to + "\n" }.joined().utf8))
    }

    init(_ data: Data) {
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        // A list that ends in a newline, as each line written does, ends in an empty part.
        if parts.last?.isEmpty == true { parts.removeLast() }
        for (offset, bytes) in parts.enumerated() {
            let number = offset + 1
            guard offset < parts.count - 1 || data.last == 0x0A else {
                problems.append(
                    MoveListProblem(
                        line: number,
                        reason: "it doesn't end in a newline, so it may be cut short; run the"
                            + " import again once the list is written"))
                continue
            }
            guard let text = String(data: Data(bytes), encoding: .utf8) else {
                problems.append(MoveListProblem(line: number, reason: "it isn't UTF-8 text"))
                continue
            }
            let fields = text.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 else {
                problems.append(
                    MoveListProblem(
                        line: number,
                        reason: "it has \(fields.count - 1) tabs, not one between the old path"
                            + " and the new: \(terminalSafe(text))"))
                continue
            }
            let from = String(fields[0])
            let to = String(fields[1])
            guard isAbsolute(from), isAbsolute(to) else {
                problems.append(
                    MoveListProblem(
                        line: number,
                        reason: "its paths aren't both absolute: \(terminalSafe(text))"))
                continue
            }
            guard
                from.precomposedStringWithCanonicalMapping
                    != to.precomposedStringWithCanonicalMapping
            else {
                problems.append(
                    MoveListProblem(
                        line: number,
                        reason: "its old and new paths are the same: \(terminalSafe(from))"))
                continue
            }
            lines.append(Line(number: number, from: from, to: to))
        }
    }
}

private func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") && path.count > 1 }
