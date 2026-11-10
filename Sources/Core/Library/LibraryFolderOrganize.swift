import Darwin
import DisplayText
import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// What Keep Files Organized, or Organize Selected Files, would do or did to some files in
/// the library folder (ADR 0164).
public struct FilesOrganized: Equatable, Sendable {
    /// Each file renamed, or to be, from its path to the one its tags give it.
    public var moved: [TrackMove] = []
    /// Files already at the path their tags give them.
    public var inPlace = 0
    /// Files outside the library folder, which are never moved.
    public var outside: [String] = []
    /// Why each file that should have moved didn't: its path taken, its tags unreadable, a
    /// failed rename. One line each, for the Problems window.
    public var problems: [String] = []
    /// Folders a move took the last audio file from that still hold other files, such as
    /// cover art, which are left where they are.
    var keptFolders: [String] = []

    init() {}

    /// `outside` and `problems` as lines for the Problems window.
    public var problemLines: [String] {
        outside.map { MoveRefusal.outsideLibrary($0).description } + problems
            + keptFolders.map { "\($0): left in place, it holds files that aren't audio" }
    }
}

/// Where each of `paths` goes in `libraryFolder` by its tags (ADR 0124's layout), with nothing
/// renamed: what Organize Selected Files asks about, and what `moveToLayout` then does. A path
/// named twice counts once; a path taken, on disk or by an earlier file of `paths`, is a
/// problem. On a volume that ignores case, a folder an earlier file of `paths` goes to keeps
/// that file's spelling, as the folder will once the earlier move makes it, and names are
/// compared as the volume compares them. Reads the files, so call it off the main thread.
/// `counted` is told after each path how many it has checked and how many of them move, and
/// `stopped` is asked before each one: once it says yes, the rest are left out unread.
public func layoutMoves(
    _ paths: [String], libraryFolder: String,
    counted: (_ checked: Int, _ moving: Int) -> Void = { _, _ in },
    stopped: () -> Bool = { false }
) -> FilesOrganized {
    var plan = FilesOrganized()
    guard let library = resolved(libraryFolder) else {
        plan.problems = [MoveRefusal.notFound(libraryFolder).description]
        return plan
    }
    var spelling = Spelling(libraryFolder)
    var named: Set<String> = []
    var destinations: Set<String> = []
    for (checked, path) in paths.enumerated() {
        guard !stopped() else { break }
        defer { counted(checked + 1, plan.moved.count) }
        guard named.insert(nfc(path)).inserted else { continue }
        switch place(path, libraryFolder: libraryFolder, resolvedLibrary: library) {
        case .outside: plan.outside.append(path)
        case .inPlace: plan.inPlace += 1
        case .problem(let line): plan.problems.append(line)
        case .move(let found):
            let destination = spelling.respelled(found)
            if pathExists(destination)
                || !destinations.insert(spelling.key(destination)).inserted
            {
                plan.problems.append(taken(path, destination))
            } else {
                plan.moved.append(TrackMove(from: path, to: destination))
            }
        }
    }
    return plan
}

/// Renames the files of `plan`, which `layoutMoves` made, never over a file and never to
/// another volume, and removes the folders that leaves empty, never the library folder itself
/// (ADR 0164). A file whose path is taken by then is left where it is and listed. With
/// `checkingAgain`, for a plan the user confirmed a while ago, a file is first read again and
/// skipped and listed unless it's still where the plan found it and still goes where the plan
/// says. Every move is recorded in the index at `ledger` before the first rename, and those
/// that didn't happen are dropped after, so `carryLayoutMoves` carries the stats of those that
/// did, now or after a failure. Blocks on the volume, so call it off the main thread, and from
/// one queue at a time: the tag writes'. `progress` is told before each file, and once more
/// when the renames are done.
public func moveToLayout(
    _ plan: FilesOrganized, libraryFolder: String, checkingAgain: Bool, ledger: URL,
    progress: (OrganizeProgress) -> Void
) -> FilesOrganized {
    moveToLayout(
        plan, libraryFolder: libraryFolder, checkingAgain: checkingAgain,
        ledger: { try LibraryIndex(at: ledger) }, calls: MoveCalls(), progress: progress)
}

func moveToLayout(
    _ plan: FilesOrganized, libraryFolder: String, checkingAgain: Bool = false,
    ledger: () throws -> LibraryIndex, calls: MoveCalls,
    progress: (OrganizeProgress) -> Void = { _ in }
) -> FilesOrganized {
    var result = plan
    result.moved = []
    guard let library = resolved(libraryFolder) else {
        result.problems += plan.moved.map { _ in MoveRefusal.notFound(libraryFolder).description }
        return result
    }
    let index: LibraryIndex
    do {
        index = try ledger()
        try index.recordLayoutMoves(plan.moved)
    } catch {
        result.problems += plan.moved.map {
            notMoved($0.from, .failed($0.from, $0.to, "its move couldn't be recorded: \(error)"))
        }
        return result
    }
    let spelling = Spelling(libraryFolder)
    var left: Set<String> = []
    for (done, move) in plan.moved.enumerated() {
        progress(OrganizeProgress(done: done, total: plan.moved.count, current: move.from))
        if checkingAgain, let changed = changedSince(move, libraryFolder, spelling) {
            result.problems.append(changed)
        } else if let problem = rename(move.from, to: move.to, library, calls) {
            result.problems.append(problem)
        } else {
            result.moved.append(move)
            left.insert(parentOf(move.from))
        }
    }
    progress(OrganizeProgress(done: plan.moved.count, total: plan.moved.count, current: nil))
    result.keptFolders = removeEmptied(left, library)
    let moved = Set(result.moved.map(\.from))
    do {
        try index.forgetLayoutMoves(plan.moved.map(\.from).filter { !moved.contains($0) })
    } catch {
        // `carryLayoutMoves` drops a move whose file is still at its old path.
        logger.error("couldn't drop the moves that didn't happen: \(error)")
    }
    return result
}

/// The folders a plan's earlier moves will make, as they'll be spelled, so a later file's
/// folder that the volume holds to be the same name takes that spelling.
private struct Spelling {
    let libraryFolder: String
    let ignoresCase: Bool
    /// Each folder planned, by `key`, as the first file to go there spells it.
    var folders: [String: String] = [:]

    init(_ libraryFolder: String) {
        self.libraryFolder = libraryFolder
        ignoresCase = pathconf(libraryFolder, _PC_CASE_SENSITIVE) == 0
    }

    /// `path` as the volume compares names.
    func key(_ path: String) -> String {
        ignoresCase ? nfc(path).folding(options: .caseInsensitive, locale: nil) : nfc(path)
    }

    /// `destination`, a path in the library folder, with each of its folders spelled as an
    /// earlier destination spelled it.
    mutating func respelled(_ destination: String) -> String {
        let parts = destination.dropFirst(libraryFolder.count + 1).split(separator: "/")
        var path = libraryFolder
        for part in parts.dropLast() {
            let next = path + "/" + part
            path = folders[key(next)] ?? next
            folders[key(path)] = path
        }
        return path + "/" + (parts.last.map(String.init) ?? "")
    }
}

/// Why `move`'s file no longer goes where its plan said, nil when it still does.
private func changedSince(_ move: TrackMove, _ libraryFolder: String, _ spelling: Spelling)
    -> String?
{
    guard pathExists(move.from) else {
        return "\(move.from): not moved, it isn't there any more"
    }
    let now: String
    do throws(LayoutProblem) {
        now = try layoutDestination(of: move.from, in: libraryFolder)
    } catch {
        switch error {
        case .unreadable(let detail):
            return notMoved(move.from, MoveRefusal.unreadable(move.from, detail))
        case .unlisted(let detail):
            return MoveRefusal.failed(move.from, libraryFolder, detail).description
        }
    }
    guard spelling.key(now) == spelling.key(move.to) else {
        return "\(move.from): not moved, its tags changed after Organize Selected Files asked"
    }
    return nil
}

/// Where a file goes.
private enum Place {
    case outside
    case inPlace
    case move(String)
    case problem(String)
}

private func place(_ path: String, libraryFolder: String, resolvedLibrary library: String)
    -> Place
{
    guard let real = resolved(path), isPath(real, under: library) else { return .outside }
    let destination: String
    do throws(LayoutProblem) {
        destination = try layoutDestination(of: path, in: libraryFolder)
    } catch {
        switch error {
        case .unreadable(let detail):
            return .problem(notMoved(path, MoveRefusal.unreadable(path, detail)))
        case .unlisted(let detail):
            return .problem(MoveRefusal.failed(path, libraryFolder, detail).description)
        }
    }
    return isSameFile(destination, path) ? .inPlace : .move(destination)
}

/// Whether `one` and `other` name one file, whatever links or spellings lead to it.
private func isSameFile(_ one: String, _ other: String) -> Bool {
    if nfc(one) == nfc(other) { return true }
    var first = stat()
    var second = stat()
    return stat(one, &first) == 0 && stat(other, &second) == 0 && first.st_dev == second.st_dev
        && first.st_ino == second.st_ino
}

/// Renames `path` to `destination`, making its folders; nil when it moved, else why not. The
/// folders it made for a file that didn't move are removed while they're empty.
private func rename(
    _ path: String, to destination: String, _ library: String, _ calls: MoveCalls
) -> String? {
    let parent = parentOf(destination)
    guard isFolder(parent, in: library) else {
        return notMoved(path, .outsideLibrary(parent))
    }
    if pathExists(destination) { return taken(path, destination) }
    var made: [String] = []
    var missing = parent
    while !pathExists(missing), missing != "/" {
        made.append(missing)
        missing = parentOf(missing)
    }
    let problem = renameMaking(path, to: destination, library, calls)
    if problem != nil {
        // The deepest first; `rmdir` refuses one another move has put a file in since.
        for folder in made where rmdir(folder) != 0 { break }
    }
    return problem
}

private func renameMaking(
    _ path: String, to destination: String, _ library: String, _ calls: MoveCalls
) -> String? {
    let parent = parentOf(destination)
    do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    } catch {
        return MoveRefusal.failed(path, destination, error.localizedDescription).description
    }
    // The folders just made could be a link someone else put there in between.
    guard isFolder(parent, in: library) else {
        return notMoved(path, .outsideLibrary(parent))
    }
    switch renameNeverOver(path, to: destination, calls) {
    case 0: return nil
    case EEXIST: return taken(path, destination)
    case EXDEV:
        return "\(path): not moved, \(destination) is on another volume, and a move there would"
            + " be a copy and a delete"
    case let code: return MoveRefusal.failed(path, destination, errorText(code)).description
    }
}

private func notMoved(_ path: String, _ refusal: MoveRefusal) -> String {
    "\(path): not moved, \(refusal)"
}

private func taken(_ path: String, _ destination: String) -> String {
    notMoved(path, .collisions([destination]))
}

/// Removes each of `folders`, and then its parents, while it's empty and inside the library
/// folder; `rmdir` refuses a folder with anything in it, cover art or a `.DS_Store` included.
/// Returns those of `folders` kept with no audio file left in them but some other file a user
/// would see.
private func removeEmptied(_ folders: Set<String>, _ library: String) -> [String] {
    var kept: [String] = []
    // The deepest first, so a parent is tried once its children are gone.
    for folder in folders.sorted(by: { $0.count > $1.count }) {
        var current = folder
        while let real = resolved(current), isPath(real, under: library), rmdir(current) == 0 {
            current = parentOf(current)
        }
        if current == folder, holdsOnlyOtherFiles(folder) { kept.append(folder) }
    }
    return kept.sorted()
}

/// Whether `folder` holds no audio file or folder, and some file that isn't hidden.
private func holdsOnlyOtherFiles(_ folder: String) -> Bool {
    // Only a note: a folder that can't be listed was kept by `rmdir` all the same.
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
        return false
    }
    let shown = names.filter { !$0.hasPrefix(".") }
    return !shown.isEmpty
        && !shown.contains { name in
            audioFileExtensions.contains((name as NSString).pathExtension.lowercased())
                || pathIsDirectory(folder + "/" + name)
        }
}

private func parentOf(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
