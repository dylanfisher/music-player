import Foundation
import Log

/// The owner's reference corpus, which is only ever read (ADR 0020).
let referenceCorpusPath = "/Users/dylanfisher/Music/music-player/test"

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
/// outside the reference corpus and `/Volumes`. Called before every write the tool makes.
func requireCorpusWrite(_ path: String, roots: [URL]) throws {
    let resolved = resolvedPath(path)
    for forbidden in [referenceCorpusPath, "/Volumes"]
    where resolved == resolvedPath(forbidden) || resolved.hasPrefix(resolvedPath(forbidden) + "/") {
        throw CorpusError("refusing to write \(path): it's under \(forbidden)")
    }
    let allowed = roots.map { resolvedPath($0.path) }
    guard allowed.contains(where: { resolved.hasPrefix($0 + "/") }) else {
        throw CorpusError(
            "refusing to write \(path): it isn't under \(roots.map(\.path).joined(separator: " or "))"
        )
    }
}

/// `path` with ".." and symbolic links resolved, as far up as the path exists, so a link can't
/// lead a write out of the clone folder.
func resolvedPath(_ path: String) -> String {
    let standard = URL(fileURLWithPath: path).standardizedFileURL.path
    var existing = standard
    var rest: [String] = []
    while !FileManager.default.fileExists(atPath: existing), existing != "/" {
        rest.insert((existing as NSString).lastPathComponent, at: 0)
        existing = (existing as NSString).deletingLastPathComponent
    }
    guard let real = realpath(existing, nil) else { return standard }
    defer { free(real) }
    return ([String(cString: real)] + rest).joined(separator: "/")
        .replacingOccurrences(of: "//", with: "/")
}
