import Foundation
import Playback

/// A track that failed to open because its file isn't at its path, so the user is told that
/// rather than that macOS can't decode it.
struct MissingFileError: PlaybackFailure {
    /// The name of the volume under `/Volumes` the path is on, when that isn't mounted.
    var unmountedVolume: String?

    var description: String {
        unmountedVolume.map { "the file's volume, \($0), isn't mounted" } ?? "no file at its path"
    }

    var userMessage: String {
        unmountedVolume.map { "the volume “\($0)” isn't mounted" } ?? "the file is missing"
    }
}

extension MissingFileError {
    /// The error for `url` when its file isn't there, or nil when it is. `volumes` is where
    /// macOS mounts volumes; tests pass a folder of their own.
    init?(_ url: URL, volumes: String = "/Volumes") {
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        let components = url.standardizedFileURL.pathComponents
        let base = URL(fileURLWithPath: volumes).standardizedFileURL.pathComponents
        guard components.count > base.count + 1, Array(components.prefix(base.count)) == base
        else {
            unmountedVolume = nil
            return
        }
        let name = components[base.count]
        let mountPoint = (volumes as NSString).appendingPathComponent(name)
        unmountedVolume = isMountPoint(mountPoint) ? nil : name
    }
}

/// Whether `path` is a mounted volume's root: a folder on another device than its parent. A
/// share that's gone leaves no folder, or an empty one on the startup disk.
private func isMountPoint(_ path: String) -> Bool {
    var own = stat()
    var parent = stat()
    guard stat(path, &own) == 0,
        stat((path as NSString).deletingLastPathComponent, &parent) == 0
    else { return false }
    return own.st_dev != parent.st_dev
}
