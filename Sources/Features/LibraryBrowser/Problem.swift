import Library
import Settings

/// One row of the Problems window, and what it offers besides Dismiss (ADR 0053).
struct Problem: Equatable, Sendable {
    enum Fix: Equatable, Sendable {
        /// A Lost Stats path, whose file left: take it out of the library (ADR 0050), so its
        /// stats stop waiting for a track and a file that comes back stays out.
        case remove(pathID: Int64)
        /// A Removed path: let scans add it again.
        case restore(pathID: Int64)
    }

    /// As the window shows it, and as a dismissal stores it.
    var line: String
    var fix: Fix?

    init(_ line: String, fix: Fix? = nil) {
        self.line = line
        self.fix = fix
    }
}

/// What the Problems window's buttons do to the rows selected.
enum ProblemAction: CaseIterable, Sendable {
    case dismiss
    case remove
    case restore

    var title: String {
        switch self {
        case .dismiss: "Dismiss"
        case .remove: "Remove from Library"
        case .restore: "Restore"
        }
    }

    /// Whether the action applies to `selected`: Dismiss to any rows, the others only when
    /// every row selected has their fix, so one click never does two different things.
    func applies(to selected: [Problem]) -> Bool {
        guard !selected.isEmpty else { return false }
        switch self {
        case .dismiss: return true
        case .remove, .restore: return pathIDs(of: selected) != nil
        }
    }

    /// The path IDs of `selected` when each one's fix is this action's; nil otherwise.
    func pathIDs(of selected: [Problem]) -> [Int64]? {
        var ids: [Int64] = []
        for problem in selected {
            switch (self, problem.fix) {
            case (.remove, .remove(let id)?), (.restore, .restore(let id)?): ids.append(id)
            default: return nil
            }
        }
        return ids
    }
}

/// The lines `findings` lists for `check`, each Lost Stats path with Remove from Library and
/// each Removed one with Restore. The "… and N more" line has no path, so no fix.
func healthProblems(_ findings: HealthFindings, of check: HealthCheck) -> [Problem] {
    findings.lines.enumerated().map { position, line in
        guard position < findings.pathIDs.count else { return Problem(line) }
        let id = findings.pathIDs[position]
        switch check {
        case .lostStats: return Problem(line, fix: .remove(pathID: id))
        case .removed: return Problem(line, fix: .restore(pathID: id))
        default: return Problem(line)
        }
    }
}
