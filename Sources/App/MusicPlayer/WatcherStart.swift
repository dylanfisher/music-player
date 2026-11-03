import Foundation
import Library
import Log
import Settings

private let logger = moduleLogger()

/// A watcher started on the watched folders the config file gives, or nil while it gives none:
/// it is blocked, gone, or doesn't name them (ADR 0082).
@MainActor
func startedWatcher(
    _ settings: ConfigStore<AppSettings>, databaseURL: URL,
    events: @escaping @Sendable (WatcherEvent) -> Void
) -> LibraryWatcher? {
    guard let folders = settings.fileValue(\.watchedFolders) else {
        logger.notice(
            "not watching the library: \(settings.fileURL.path) doesn't give the watched folders")
        return nil
    }
    let watcher = LibraryWatcher(
        databaseURL: databaseURL, networkReaders: settings[\.networkScanReaders], events: events)
    watcher.start(
        folders: folders, syncFolder: settings[\.syncFolder],
        rescanNetworkFoldersAtLaunch: settings[\.rescanNetworkFoldersAtLaunch],
        pausePollingDuringPlayback: settings[\.pausePollingDuringPlayback])
    return watcher
}

/// Stop Watching: takes `folder` out of the setting, which restarts the watcher without it and
/// removes its files from the index. The last folder's are removed here, since the watcher never
/// empties the index for no folders (ADR 0082). `watcher` is the watcher in effect after the
/// change.
@MainActor
func stopWatching(
    _ folder: WatchedFolder, _ settings: ConfigStore<AppSettings>,
    watcher: () -> LibraryWatcher?
) throws {
    // Found again by value: the file can change while the confirmation is open.
    var folders = settings[\.watchedFolders]
    guard let position = folders.firstIndex(of: folder) else { return }
    folders.remove(at: position)
    try settings.set(\.watchedFolders, to: folders)
    guard folders.isEmpty else { return }
    guard let watcher = watcher() else {
        throw ConfigProblem(
            line: nil, message: "the library isn't watched, so \(folder.path)'s tracks stay")
    }
    watcher.removeEveryFile()
}
