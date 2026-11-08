import Foundation
import Testing

@testable import Settings

private let schema = AppSettings()

/// Every problem `text` has, or nil when it parses.
private func problems(_ text: String) -> [String]? {
    do {
        _ = try ConfigFile.parse(
            ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
            conflicts: schema.conflicts)
        return nil
    } catch {
        return error.problems.map(\.description)
    }
}

@Test func snapshotsGoToBackupsInTheDataFolderUnlessTheFolderIsSet() {
    let paths = AppPaths(home: URL(fileURLWithPath: "/tmp/home", isDirectory: true))
    #expect(schema.snapshotFolder.defaultValue == nil)
    #expect(paths.snapshotDirectory(nil).path == "/tmp/home/Backups")
    #expect(paths.snapshotDirectory("/Volumes/big/Snapshots").path == "/Volumes/big/Snapshots")
}

@Test func theSnapshotFolderIsOutsideEveryWatchedFolderAndTheSyncFolder() {
    let others =
        #""library.watchedFolders": [{"path": "/Users/me/Music", "kind": "local", "include": [], "exclude": [], "pollIntervalMinutes": null}], "sync.folder": {"path": "/Users/me/Sync"}"#
    for outside in ["/Users/me/Backups", "/Users/me/Music Snapshots", "/Users/me/Synced"] {
        #expect(problems(#"{"library.snapshotFolder": "\#(outside)", \#(others)}"#) == nil)
    }
    for (inside, problem) in [
        ("/Users/me/Music", "outside every watched folder"),
        ("/Users/me/Music/Backups", "outside every watched folder"),
        ("/Users/me/./Music/x/../Backups", "outside every watched folder"),
        ("/Users/me/Sync/Backups", "inside the sync folder"),
    ] {
        let found = problems(#"{"library.snapshotFolder": "\#(inside)", \#(others)}"#)
        #expect(found?.count == 1, "\(inside)")
        #expect(found?.first?.contains(problem) == true, "\(found ?? [])")
    }
}
