import Foundation
import Log

/// The owner's reference corpus, which is only ever read (ADR 0020).
let referenceCorpusPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Music/music-player/test").path

/// Where corpus runs write: APFS clones of the reference, made again before each run by
/// `scripts/tag-corpus`.
func cloneFolder() throws -> URL {
    try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    )
    .appendingPathComponent(appDirectoryName).appendingPathComponent("tag-corpus")
}

/// The folders under which the tool may write: the clone folder and the temp directory, which
/// the tests use.
func writableRoots() throws -> [URL] {
    [try cloneFolder(), FileManager.default.temporaryDirectory]
}

/// Fails unless `path` is inside one of `roots` once symbolic links and ".." are resolved, and
/// outside the reference corpus and `/Volumes`. A path must exist, or be a new name in a folder
/// that does; a dangling link or a missing folder on the way is refused. Called before every
/// write the tool makes.
func requireCorpusWrite(_ path: String, roots: [URL]) throws {
    let resolved = try resolvedPath(path)
    for forbidden in [referenceCorpusPath, "/Volumes"] {
        // A forbidden folder that doesn't exist on this Mac is compared as written.
        let place = (try? resolvedPath(forbidden)) ?? forbidden
        if resolved == place || resolved.hasPrefix(place + "/") {
            throw CorpusError("refusing to write \(path): it's under \(forbidden)")
        }
    }
    let allowed = try roots.map { try resolvedPath($0.path) }
    guard allowed.contains(where: { resolved.hasPrefix($0 + "/") }) else {
        throw CorpusError(
            "refusing to write \(path): it isn't under \(roots.map(\.path).joined(separator: " or "))"
        )
    }
}

/// `path` with ".." and symbolic links resolved. Throws for a path that is a dangling link or
/// whose folder doesn't resolve.
func resolvedPath(_ path: String) throws -> String {
    let standard = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    if let real = realpath(standard, nil) {
        defer { free(real) }
        return String(cString: real)
    }
    var info = stat()
    guard lstat(standard, &info) != 0, errno == ENOENT else {
        throw CorpusError("refusing \(path): it's a link to nothing, or can't be resolved")
    }
    let folder = (standard as NSString).deletingLastPathComponent
    guard let real = realpath(folder, nil) else {
        throw CorpusError("refusing \(path): its folder \(folder) doesn't resolve")
    }
    defer { free(real) }
    return String(cString: real) + "/" + (standard as NSString).lastPathComponent
}
