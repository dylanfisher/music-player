import DisplayText
import Library
import Metadata
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

    /// As ⌘C copies it, and as a dismissal stores it.
    var line: String
    var fix: Fix?
    /// What sort of problem it is, for the Kind column: "Tag warning", "Organizing".
    var kind: String
    /// The file or folder it's about, nil for a problem about neither.
    var path: String?
    /// What's wrong, without the path.
    var detail: String
    /// The track at `path`, "Artist – Title", looked up when the window lists the rows.
    var track: String?

    /// A problem whose line is "<path>: <detail>", or just a path, when it starts with a "/";
    /// any other line is all detail. A path that holds ": " splits early, which only the File
    /// and Folder columns show: the line stays whole.
    init(_ line: String, kind: String = "", fix: Fix? = nil) {
        var path: String?
        var detail = line
        if line.hasPrefix("/") {
            if let colon = line.range(of: ": ") {
                path = String(line[..<colon.lowerBound])
                detail = String(line[colon.upperBound...])
            } else {
                path = line
                detail = ""
            }
        }
        self.init(line, kind: kind, path: path, detail: detail, fix: fix)
    }

    init(_ line: String, kind: String, path: String?, detail: String, fix: Fix? = nil) {
        self.line = line
        self.fix = fix
        self.kind = kind
        self.path = path
        self.detail = detail
    }

    /// A file the index stores a warning or failure for, the failure said plainly first.
    init(_ issue: FileIssue) {
        let kind: String
        var detail = issue.detail + byteNote(issue.offset)
        switch issue.problem {
        case .warning(let warning):
            kind = ProblemKind.tagWarning
            detail = ProblemKind.warning(warning) + ": " + detail
        case .failure(let failure):
            kind = ProblemKind.unreadable
            detail = failure.userMessage + ": " + detail
        }
        self.init(issue.description, kind: kind, path: issue.path, detail: detail)
    }

    /// What the last scan of a folder found wrong with it or an entry in it.
    init(_ issue: ScanIssue) {
        self.init(
            issue.description, kind: ProblemKind.folder(issue.kind), path: issue.path,
            detail: issue.detail)
    }

    /// The problem with `kind` given, unless it has its own.
    func kinded(_ kind: String) -> Problem {
        var problem = self
        if problem.kind.isEmpty { problem.kind = kind }
        return problem
    }
}

/// The Kind column's words for the problems from each place (ADR 0175).
enum ProblemKind {
    static let notice = "Notice"
    static let sync = "Sync"
    static let scanFailed = "Scan failed"
    static let unreadable = "Can't read"
    static let tagWarning = "Tag warning"
    static let imported = "Import or export"
    static let added = "Adding files"
    static let organized = "Organizing"
    static let movesImported = "Move list"

    /// What a stored tag warning means, for the Detail column before the reader's own words.
    static func warning(_ kind: MetadataWarning.Kind) -> String {
        switch kind {
        case .badNumber: "a track or disc number isn't a plain number, its first digits kept"
        case .badText: "text isn't valid in its encoding, so it was read leniently"
        case .badValue: "a value its field can't hold was left out"
        case .unreadableField: "a tag field or picture can't be read and was skipped"
        case .nonSyncsafeFrameSize: "an ID3 frame size is written the way old iTunes wrote it"
        case .truncated: "the file is shorter than its header says"
        }
    }

    /// A folder's scan issue in a few words.
    static func folder(_ kind: ScanIssue.Kind) -> String {
        switch kind {
        case .rootUnavailable: "Folder not there"
        case .rootEmpty: "Folder empty"
        case .rootVanished: "Folder went away"
        case .listedTwice: "Listed twice"
        case .unreadable: "Can't list"
        case .symbolicLink: "Link not followed"
        case .networkFolderMarkedLocal: "Network folder"
        case .stagingFolderSkipped: "Staging folder skipped"
        case .insideStagingFolder: "In the staging folder"
        }
    }
}

/// "1 problem", "3 problems".
func problemCount(_ value: Int) -> String { count(value, "problem") }

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
        guard position < findings.pathIDs.count else { return Problem(line, kind: check.title) }
        let id = findings.pathIDs[position]
        switch check {
        case .lostStats: return Problem(line, kind: check.title, fix: .remove(pathID: id))
        case .removed: return Problem(line, kind: check.title, fix: .restore(pathID: id))
        default: return Problem(line, kind: check.title)
        }
    }
}
