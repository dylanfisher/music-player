import Foundation

/// The extensions the scanner reads, lowercased. Anything else is counted and skipped, so cover
/// art, cue sheets and logs beside the music cost no reads.
let audioFileExtensions: Set<String> = ["flac", "m4a", "mp4", "mp3", "wav", "aif", "aiff", "aifc"]

/// An audio file the walk found, with its size and mtime from the directory listing.
struct WalkedFile: Sendable {
    var path: String
    var sizeBytes: Int
    var modifiedSeconds: Double
}

/// What walking one or more directories found.
struct DirectoryWalk {
    var files: [WalkedFile] = []
    var otherFiles = 0
    /// Entries in the first directory listed, to tell an empty mount point from a library.
    var startEntries = 0
    var issues: [ScanIssue] = []
    var cancelled = false
}

/// Resource values fetched with each directory listing. `contentsOfDirectory` gets them in bulk
/// with the listing (`getattrlistbulk`), which is the one stat per entry the walk makes; on SMB
/// that's a round trip per batch of entries rather than per file.
private let walkKeys: [URLResourceKey] = [
    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    .contentModificationDateKey,
]
private let walkKeySet = Set(walkKeys)

/// Walks `start` and everything under it that `filter` includes, skipping hidden entries such as
/// `.DS_Store` and the `._` files macOS leaves on SMB shares. `root` is the watched folder, which
/// the filter's patterns are relative to. Checks `control` before each directory, and calls
/// `found` after each one with the audio files found so far.
func walk(
    _ start: String, root: String, filter: FolderFilter, control: ScanControl,
    found: (Int) -> Void
) -> DirectoryWalk {
    var result = DirectoryWalk()
    var pending = [start]
    var isStart = true
    while let directory = pending.popLast() {
        guard control.proceed() else {
            result.cancelled = true
            return result
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                includingPropertiesForKeys: walkKeys, options: [.skipsHiddenFiles])
        } catch {
            result.issues.append(
                ScanIssue(
                    kind: .unreadable, path: directory, detail: "\(error.localizedDescription)"))
            continue
        }
        if isStart {
            result.startEntries = entries.count
            isStart = false
        }
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
                if filter.includesDirectory(relative) { pending.append(path) }
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
                        path: path, sizeBytes: size,
                        modifiedSeconds: modified.timeIntervalSince1970))
            }
        }
        found(result.files.count)
    }
    return result
}
