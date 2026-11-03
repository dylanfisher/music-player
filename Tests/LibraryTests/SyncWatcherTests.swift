import Foundation
import Testing

@testable import Library
@testable import Settings

/// The syncs a watcher reported.
private final class Syncs: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [SyncReport] = []
    private var failures: [String] = []
    private var scans = 0
    private var scansBeforeSync: Int?

    func append(_ event: WatcherEvent) {
        lock.withLock {
            switch event {
            case .synced(let report):
                reports.append(report)
                if scansBeforeSync == nil { scansBeforeSync = scans }
            case .syncFailed(let reason): failures.append(reason)
            case .scanned: scans += 1
            default: break
            }
        }
    }

    var count: Int { lock.withLock { reports.count } }
    var failed: [String] { lock.withLock { failures } }
    /// The scans that ended before the first sync did.
    var scansBeforeFirstSync: Int? { lock.withLock { scansBeforeSync } }
}

/// Polls `condition` every 50 ms for up to `seconds`, and records what it last saw.
private func eventually(
    within seconds: Double, _ what: String, _ condition: () throws -> Bool
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try condition() { return true }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let met = try condition()
    if !met { Issue.record("timed out waiting for \(what)") }
    return met
}

@Test func theWatcherSyncsAtStartAndPushesAfterAnEdit() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sync-watcher-\(UUID().uuidString)")
    let sync = root.appendingPathComponent("sync").path
    let mount = root.appendingPathComponent("music").path
    try FileManager.default.createDirectory(
        atPath: mount + "/library", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: sync, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("library.sqlite")
    let index = try LibraryIndex(at: databaseURL)
    let log = sync + "/" + syncLogName(try index.machineID())
    let syncs = Syncs()
    let watcher = LibraryWatcher(
        databaseURL: databaseURL, networkReaders: 2,
        mounts: FakeMounts([MountedShare(url: "smb://nas/music", mountPoint: mount)]),
        events: syncs.append)
    watcher.start(
        folders: [WatchedFolder(path: "library", share: "smb://nas/music", kind: .network)],
        syncFolder: SyncFolder(path: sync), rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false)
    defer { watcher.stop() }
    #expect(try await eventually(within: 10, "the first sync") { syncs.count >= 1 })
    let before = syncs.count
    try index.recordPlay(mount + "/library/a.flac", at: 1_700_000_000)
    watcher.pushSync()
    #expect(
        try await eventually(within: 10, "the push") {
            (try? String(contentsOfFile: log, encoding: .utf8))?.contains("\"play\"") == true
        })
    #expect(try await eventually(within: 10, "its report") { syncs.count > before })
    #expect(syncs.failed.isEmpty)
}

@Test func theLaunchScanRunsBeforeTheFirstSync() async throws {
    let library = try TestLibrary()
    let sync = FileManager.default.temporaryDirectory
        .appendingPathComponent("sync-first-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sync) }
    let syncs = Syncs()
    let watcher = LibraryWatcher(
        databaseURL: library.databaseURL, networkReaders: nil, events: syncs.append)
    watcher.start(
        folders: [library.folder], syncFolder: SyncFolder(path: sync.path),
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: false)
    defer { watcher.stop() }
    #expect(try await eventually(within: 30, "the first sync") { syncs.count >= 1 })
    #expect(syncs.scansBeforeFirstSync == 1)
    #expect(syncs.failed.isEmpty)
}

@Test func aSyncFolderInsideAWatchedFolderIsRefused() async throws {
    let library = try TestLibrary()
    let syncs = Syncs()
    let watcher = LibraryWatcher(
        databaseURL: library.databaseURL, networkReaders: nil, events: syncs.append)
    // Stored by path inside a folder stored by path, which only the found paths can show
    // when the config can't, as when one is by share.
    watcher.start(
        folders: [library.folder], syncFolder: SyncFolder(path: library.root + "/Sync"),
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: false)
    defer { watcher.stop() }
    #expect(try await eventually(within: 10, "the refusal") { !syncs.failed.isEmpty })
    #expect(syncs.failed.first?.contains("inside the watched folder") == true)
    #expect(syncs.count == 0)
}

@Test func withTheShareAwayTheWatcherSyncsWhenItsMountedAgain() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sync-watcher-\(UUID().uuidString)")
    let mount = root.appendingPathComponent("music").path
    try FileManager.default.createDirectory(
        atPath: mount + "/sync", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("library.sqlite")
    let index = try LibraryIndex(at: databaseURL)
    let log = mount + "/sync/" + syncLogName(try index.machineID())
    let mounts = FakeMounts([])
    let syncs = Syncs()
    let watcher = LibraryWatcher(
        databaseURL: databaseURL, networkReaders: 2, mounts: mounts, events: syncs.append)
    watcher.start(
        folders: [], syncFolder: SyncFolder(path: "sync", share: "smb://nas/music"),
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: false)
    defer { watcher.stop() }
    watcher.pushSync()
    // Nothing is mounted, so nothing syncs, and nothing fails either.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(syncs.count == 0 && syncs.failed.isEmpty)
    mounts.set([MountedShare(url: "smb://nas/music", mountPoint: mount)])
    watcher.sharesMayHaveMoved()
    #expect(try await eventually(within: 10, "the sync after the mount") { syncs.count == 1 })
    #expect(FileManager.default.fileExists(atPath: log))
}
