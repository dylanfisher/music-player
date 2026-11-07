import Foundation
import Settings

/// What adding files dropped on the library window does (ADR 0124): which folders become
/// watched once the user agrees, which directories already watched are scanned again, and which
/// files are copied into the library folder first.
public struct AddPlan: Equatable, Sendable {
    /// Folders no watched folder holds, outermost only, in path order.
    public var foldersToWatch: [String] = []
    /// Directories in a watched folder that hold dropped files or are dropped folders,
    /// outermost only, in path order.
    public var directoriesToRescan: [String] = []
    /// Audio files outside the library folder, in the order dropped, while copying is on.
    public var filesToCopy: [String] = []
    /// The library folder the files are copied into; nil while copying is off.
    public var libraryFolder: String?
    /// Folders that couldn't be listed and files that couldn't be stat'ed, as lines.
    public var problems: [String] = []

    /// Whether there's nothing to add.
    public var isEmpty: Bool {
        foldersToWatch.isEmpty && directoriesToRescan.isEmpty && filesToCopy.isEmpty
    }

    /// The directories to scan again once the files are copied to `copies`: none when the
    /// library folder is about to be watched, since its first scan reads them.
    public func directoriesToRescan(afterCopyingTo copies: [String]) -> [String] {
        guard let libraryFolder, !foldersToWatch.contains(libraryFolder) else { return [] }
        return outermost(copies.map { ($0 as NSString).deletingLastPathComponent })
    }
}

/// What the dropped `paths` add to the library, in a library watching the folders at `watched`
/// (where each one is now). With `libraryFolder`, the files that aren't in it are to be copied
/// into it, dropped folders listed for their audio files, and the library folder watched if no
/// watched folder holds it. Files that aren't audio are left out, as a scan leaves them out.
/// Stats and lists the volume, so call it off the main thread.
public func planAdding(
    _ paths: [String], watched: [String], libraryFolder: String?,
    access: any ScanFileAccess = SystemFileAccess()
) throws(AddError) -> AddPlan {
    var plan = AddPlan(libraryFolder: libraryFolder)
    if let libraryFolder {
        guard libraryFolder.hasPrefix("/") else { throw .libraryFolderNotAbsolute(libraryFolder) }
    }
    var places: [String] = []
    func add(file path: String) {
        guard audioFileExtensions.contains((path as NSString).pathExtension.lowercased()) else {
            return
        }
        if let libraryFolder, !isPath(path, inOrAt: libraryFolder) {
            plan.filesToCopy.append(path)
        } else {
            places.append((path as NSString).deletingLastPathComponent)
        }
    }
    for path in paths {
        let folder: Bool
        do {
            // Either; the resource value says which.
            let url = URL(fileURLWithPath: path, isDirectory: false)
            folder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            plan.problems.append("\(path): \(error.localizedDescription)")
            continue
        }
        guard folder else {
            add(file: path)
            continue
        }
        guard let libraryFolder, !isPath(path, inOrAt: libraryFolder) else {
            places.append(path)
            continue
        }
        let (files, issues) = audioFiles(under: path, access: access)
        files.forEach(add(file:))
        plan.problems += issues
    }
    var unwatched: [String] = []
    for place in places {
        if watched.contains(where: { isPath(place, inOrAt: $0) }) {
            plan.directoriesToRescan.append(place)
        } else {
            unwatched.append(place)
        }
    }
    if let libraryFolder, !plan.filesToCopy.isEmpty {
        guard isDirectory(libraryFolder) else { throw .libraryFolderMissing(libraryFolder) }
        if !watched.contains(where: { isPath(libraryFolder, inOrAt: $0) }) {
            unwatched.append(libraryFolder)
        }
    }
    plan.foldersToWatch = outermost(unwatched)
    plan.directoriesToRescan = outermost(plan.directoriesToRescan)
    return plan
}

/// Why dropped files can't be added.
public enum AddError: Error, Equatable, CustomStringConvertible {
    /// The library folder setting isn't an absolute path.
    case libraryFolderNotAbsolute(String)
    /// No folder is at the library folder's path, as when its volume isn't mounted.
    case libraryFolderMissing(String)

    public var description: String {
        switch self {
        case .libraryFolderNotAbsolute(let path):
            "the library folder \"\(path)\" isn't an absolute path"
        case .libraryFolderMissing(let path):
            "the library folder \(path) isn't there; is its volume mounted?"
        }
    }
}

/// Every audio file under `folder`, depth first in listing order, and what couldn't be listed.
private func audioFiles(under folder: String, access: any ScanFileAccess)
    -> (files: [String], issues: [String])
{
    var files: [String] = []
    var issues: [String] = []
    var pending = [folder]
    let filter = FolderFilter(include: [], exclude: [])
    while let directory = pending.popLast() {
        let listing = list(directory, root: folder, filter: filter, access: access)
        files += listing.files.map(\.path)
        issues += listing.issues.map(\.description)
        pending += listing.directories.reversed()
    }
    return (files, issues)
}

/// `paths` without those inside another one or repeated, in path order.
private func outermost(_ paths: [String]) -> [String] {
    let unique = Set(paths).sorted()
    return unique.filter { path in !unique.contains { $0 != path && isPath(path, inOrAt: $0) } }
}
