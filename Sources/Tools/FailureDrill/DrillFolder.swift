import Foundation
import Log

/// `path` resolved, once it's checked to be under ~/Library/Caches/MusicPlayer or the temp
/// directory, the only places the drill may write: never /Volumes, the owner's library, or the
/// app's real config and data folders.
func drillFolder(_ path: String) throws -> URL {
    let caches = try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent(appDirectoryName)
    let resolved = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        .standardizedFileURL.path
    guard !resolved.hasPrefix("/Volumes/") else {
        throw DrillError("refusing \(path): it's under /Volumes")
    }
    for root in [caches, FileManager.default.temporaryDirectory] {
        let allowed = root.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved.hasPrefix(allowed + "/") {
            return URL(fileURLWithPath: resolved, isDirectory: true)
        }
    }
    throw DrillError(
        "refusing \(path): the drill writes only under \(caches.path) and the temp directory")
}
