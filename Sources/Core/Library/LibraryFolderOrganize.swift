import Darwin
import DisplayText
import Foundation
import Metadata

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

    /// For the status bar: "Organized 12 files · 2 not moved".
    public var summary: String {
        var parts = ["Organized \(files(moved.count))"]
        if !problems.isEmpty { parts.append("\(problems.count) not moved") }
        if !outside.isEmpty { parts.append("\(outside.count) outside the library folder") }
        return parts.joined(separator: " · ")
    }

    /// `outside` and `problems` as lines for the Problems window.
    public var problemLines: [String] {
        outside.map { MoveRefusal.outsideLibrary($0).description } + problems
            + keptFolders.map { "\($0): left in place, it holds files that aren't audio" }
    }
}

/// Where each of `paths` goes in `libraryFolder` by its tags (ADR 0124's layout), with nothing
/// renamed: what Organize Selected Files asks about, and what `moveToLayout` then does. A path
/// named twice counts once; a path taken, on disk or by an earlier file of `paths`, is a
/// problem. Reads the files, so call it off the main thread.
public func layoutMoves(_ paths: [String], libraryFolder: String) -> FilesOrganized {
    var plan = FilesOrganized()
    guard let library = resolved(libraryFolder) else {
        plan.problems = [MoveRefusal.notFound(libraryFolder).description]
        return plan
    }
    var named: Set<String> = []
    var destinations: Set<String> = []
    for path in paths where named.insert(nfc(path)).inserted {
        switch place(path, libraryFolder: libraryFolder, resolvedLibrary: library) {
        case .outside: plan.outside.append(path)
        case .inPlace: plan.inPlace += 1
        case .problem(let line): plan.problems.append(line)
        case .move(let destination):
            if pathExists(destination) || !destinations.insert(nfc(destination)).inserted {
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
/// (ADR 0164). A file whose path is taken by then is left where it is and listed. Blocks on the
/// volume, so call it off the main thread, and from one queue at a time: the tag writes'.
public func moveToLayout(_ plan: FilesOrganized, libraryFolder: String) -> FilesOrganized {
    moveToLayout(plan, libraryFolder: libraryFolder, calls: MoveCalls())
}

func moveToLayout(_ plan: FilesOrganized, libraryFolder: String, calls: MoveCalls)
    -> FilesOrganized
{
    var result = plan
    result.moved = []
    guard let library = resolved(libraryFolder) else {
        result.problems += plan.moved.map { _ in MoveRefusal.notFound(libraryFolder).description }
        return result
    }
    var left: Set<String> = []
    for move in plan.moved {
        if let problem = rename(move.from, to: move.to, library, calls) {
            result.problems.append(problem)
        } else {
            result.moved.append(move)
            left.insert(parentOf(move.from))
        }
    }
    result.keptFolders = removeEmptied(left, library)
    return result
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
    return nfc(destination) == nfc(path) ? .inPlace : .move(destination)
}

/// Renames `path` to `destination`, making its folders; nil when it moved, else why not.
private func rename(
    _ path: String, to destination: String, _ library: String, _ calls: MoveCalls
) -> String? {
    let parent = parentOf(destination)
    guard isFolder(parent, in: library) else {
        return notMoved(path, .outsideLibrary(parent))
    }
    if pathExists(destination) { return taken(path, destination) }
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
