import Foundation
import Library
import Log
import Settings

private let logger = moduleLogger()

/// A watcher started on the watched folders the config file gives, or nil while it gives none:
/// it is blocked, gone, or doesn't name them. The default, no folders, would remove every file
/// in the index as outside them (ADR 0082).
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
