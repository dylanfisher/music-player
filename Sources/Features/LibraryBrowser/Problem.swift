import Library
import Settings

/// One row of the Problems window, and what it offers besides Dismiss (ADR 0059).
struct Problem: Equatable, Sendable {
    enum Fix: Equatable, Sendable {
        /// A Lost Stats path, whose file left: take it out of the library (ADR 0050), so its
        /// stats stop waiting for a track and a file that comes back stays out.
        case remove(pathID: Int64)
        /// A Removed path: let scans add it again.
        case restore(pathID: Int64)
        /// A path the last import found no track for: match it again under the folder the
        /// user picks.
        case locate(path: String)
    }

    /// As the window shows it, and as a dismissal stores it.
    var line: String
    var fix: Fix?

    init(_ line: String, fix: Fix? = nil) {
        self.line = line
        self.fix = fix
    }
}

/// What the Problems window's buttons do to the rows selected, or for Dismiss All to every row.
enum ProblemAction: CaseIterable, Sendable {
    case dismiss
    case dismissAll
    case remove
    case restore
    case locate

    var title: String {
        switch self {
        case .dismiss: "Dismiss"
        case .dismissAll: "Dismiss All"
        case .remove: "Remove from Library"
        case .restore: "Restore"
        case .locate: "Locate…"
        }
    }

    /// The rows the action acts on: every row for Dismiss All, selected or not, and the rows
    /// selected for the others.
    func rows(selected: [Problem], all: [Problem]) -> [Problem] {
        self == .dismissAll ? all : selected
    }

    /// Whether the action applies to `selected`, the rows it acts on: Dismiss and Dismiss All to
    /// any, Locate… to one, and the others only when every row has their fix, so one click
    /// never does two different things.
    func applies(to selected: [Problem]) -> Bool {
        guard !selected.isEmpty else { return false }
        switch self {
        case .dismiss, .dismissAll: return true
        case .remove, .restore: return pathIDs(of: selected) != nil
        case .locate: return missingPath(of: selected) != nil
        }
    }

    /// The path of the one row selected when it's an import's miss.
    func missingPath(of selected: [Problem]) -> String? {
        guard self == .locate, selected.count == 1, case .locate(let path)? = selected[0].fix
        else { return nil }
        return path
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
