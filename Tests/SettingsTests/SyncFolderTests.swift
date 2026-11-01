import Foundation
import Testing

@testable import Settings

private let schema = AppSettings()

private func parsed(_ text: String) throws(ConfigErrorList) -> ConfigContents {
    try ConfigFile.parse(
        ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
        conflicts: schema.conflicts)
}

/// A config file with `sync` as `sync.folder` and `folders` as the watched folders.
private func config(sync: String, folders: [String]) -> String {
    let watched = folders.map {
        #"{\#($0), "kind": "network", "include": [], "exclude": [], "pollIntervalMinutes": 15}"#
    }
    return
        #"{"sync.folder": {\#(sync)}, "library.watchedFolders": [\#(watched.joined(separator: ", "))]}"#
}

@Test func aSyncFolderDecodesStrictly() throws {
    #expect(
        try parsed(#"{"sync.folder": {"share": "smb://nas/music", "path": "sync"}}"#)
            .values["sync.folder"] as? SyncFolder
            == SyncFolder(path: "sync", share: "smb://nas/music"))
    for (text, problem) in [
        (#"{"sync.folder": {"path": "/s", "extra": 1}}"#, "unknown key"),
        (#"{"sync.folder": {"path": "sync"}}"#, "isn't absolute"),
        (#"{"sync.folder": {"share": "smb://nas/music", "path": "../x"}}"#, "leaves share"),
        (#"{"sync.folder": {"share": "nas", "path": "x"}}"#, "isn't a URL"),
    ] {
        do {
            _ = try parsed(text)
            Issue.record("accepted \(text)")
        } catch {
            #expect(error.problems.count == 1)
            #expect(error.problems.first?.description.contains(problem) == true, "\(error)")
        }
    }
}

@Test func aSyncFolderInsideAWatchedFolderIsRefusedOnItsLine() throws {
    let inside = [
        config(
            sync: #""path": "/Volumes/music/library/sync""#,
            folders: [#""path": "/Volumes/music/library""#]),
        config(
            sync: #""path": "/Volumes/music/library""#,
            folders: [#""path": "/Volumes/music/library/""#]),
        config(
            sync: #""share": "smb://nas/music", "path": "library/sync""#,
            folders: [#""share": "smb://192.168.1.5/Music", "path": "library""#]),
        config(
            sync: #""share": "smb://nas/music", "path": "sync""#,
            folders: [#""share": "smb://nas/music", "path": """#]),
    ]
    for text in inside {
        do {
            _ = try parsed(text)
            Issue.record("accepted \(text)")
        } catch {
            #expect(error.problems.map(\.line) == [1], "\(error)")
            #expect(error.problems.first?.message.contains("outside every watched folder") == true)
        }
    }
    let outside = [
        config(
            sync: #""path": "/Volumes/music/library-sync""#,
            folders: [#""path": "/Volumes/music/library""#]),
        config(
            sync: #""share": "smb://nas/music", "path": "sync""#,
            folders: [#""share": "smb://nas/music", "path": "library""#]),
        config(
            sync: #""share": "smb://nas/other", "path": "library""#,
            folders: [#""share": "smb://nas/music", "path": "library""#]),
    ]
    for text in outside { _ = try parsed(text) }
}

@MainActor @Test func settingAConflictingValueThrowsAndChangesNothing() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sync-folder-\(UUID().uuidString)/config.json")
    let store = ConfigStore(schema, fileURL: url, check: { _, _, _ in nil }, creating: false)
    try store.set(\.watchedFolders, to: [WatchedFolder(path: "/Music", kind: .local)])
    #expect(throws: ConfigError.self) {
        try store.set(\.syncFolder, to: SyncFolder(path: "/Music/Sync"))
    }
    #expect(store[\.syncFolder] == nil)
    try store.set(\.syncFolder, to: SyncFolder(path: "/Sync"))
    #expect(throws: ConfigError.self) {
        try store.set(\.watchedFolders, to: [WatchedFolder(path: "/Sync", kind: .local)])
    }
    #expect(store[\.watchedFolders] == [WatchedFolder(path: "/Music", kind: .local)])
}
