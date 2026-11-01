import Foundation

/// The extensions the scanner reads, lowercased. Anything else is counted and skipped, so cover
/// art, cue sheets and logs beside the music cost no reads.
public let audioFileExtensions: Set<String> = [
    "flac", "m4a", "mp4", "mp3", "wav", "aif", "aiff", "aifc",
]

/// An audio file the walk found, with its size and dates from the directory listing.
struct WalkedFile: Sendable {
    var path: String
    var sizeBytes: Int
    var modifiedSeconds: Double
    /// Nil when the volume doesn't keep creation dates.
    var createdSeconds: Double? = nil
}

/// What listing one directory found.
struct DirectoryListing {
    var files: [WalkedFile] = []
    /// Subdirectories the filter includes, in listing order.
    var directories: [String] = []
    var otherFiles = 0
    /// Every entry listed, to tell an empty mount point from a library.
    var entries = 0
    var issues: [ScanIssue] = []
}

/// Resource values fetched with each directory listing. `contentsOfDirectory` gets them in bulk
/// with the listing (`getattrlistbulk`) and makes no stat per entry (measured in ADR 0010), so
/// on SMB a directory costs a round trip per batch of entries rather than one per file.
private let walkKeys: [URLResourceKey] = [
    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    .contentModificationDateKey, .creationDateKey,
]
private let walkKeySet = Set(walkKeys)

/// Whether a subtree scan may start at `start`. It's checked like the directories the walk
/// descends through, so changes inside an excluded folder don't get it indexed.
func startIsIncluded(_ start: String, root: String, filter: FolderFilter) -> Bool {
    guard start != root else { return true }
    let components = start.dropFirst(root.count + 1).split(separator: "/")
    return components.indices.allSatisfy { end in
        filter.includesDirectory(components[...end].joined(separator: "/"))
    }
}

/// Lists `directory`, skipping hidden entries such as `.DS_Store` and the `._` files macOS
/// leaves on SMB shares. `root` is the watched folder, which the filter's patterns are relative
/// to. Files and subdirectories keep the order the volume lists them in.
func list(
    _ directory: String, root: String, filter: FolderFilter, access: any ScanFileAccess
) -> DirectoryListing {
    var result = DirectoryListing()
    let entries: [URL]
    do {
        entries = try access.contentsOfDirectory(directory, keys: walkKeys)
    } catch {
        result.issues.append(
            ScanIssue(
                kind: .unreadable, path: directory, detail: "\(error.localizedDescription)"))
        return result
    }
    result.entries = entries.count
    for entry in entries {
        // Built from `directory`, not `entry.path`, so every path keeps the root's spelling
        // even where Foundation would resolve a symbolic link such as /var.
        let path = directory + "/" + entry.lastPathComponent
        let relative = String(path.dropFirst(root.count + 1))
        let values: URLResourceValues
        do {
            values = try entry.resourceValues(forKeys: walkKeySet)
        } catch {
            result.issues.append(
                ScanIssue(
                    kind: .unreadable, path: path, detail: "\(error.localizedDescription)"))
            continue
        }
        if values.isSymbolicLink == true {
            result.issues.append(
                ScanIssue(kind: .symbolicLink, path: path, detail: "not followed"))
        } else if values.isDirectory == true {
            if filter.includesDirectory(relative) { result.directories.append(path) }
        } else if values.isRegularFile == true {
            guard audioFileExtensions.contains(entry.pathExtension.lowercased()) else {
                result.otherFiles += 1
                continue
            }
            guard filter.includesFile(relative) else { continue }
            guard let size = values.fileSize, let modified = values.contentModificationDate
            else {
                result.issues.append(
                    ScanIssue(kind: .unreadable, path: path, detail: "no size or mtime"))
                continue
            }
            result.files.append(
                WalkedFile(
                    path: path, sizeBytes: size, modifiedSeconds: modified.timeIntervalSince1970,
                    createdSeconds: values.creationDate?.timeIntervalSince1970))
        }
    }
    return result
}
