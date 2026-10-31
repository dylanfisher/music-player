import Foundation
import Testing

@testable import Library
@testable import Settings

/// Polls `condition` every 100 ms for up to `seconds`.
private func eventually(within seconds: Double, _ condition: () throws -> Bool) async throws
    -> Bool
{
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try condition() { return true }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return try condition()
}

@Test func scansAtStartThenFollowsFSEvents() async throws {
    let library = try TestLibrary()
    let watcher = LibraryWatcher(databaseURL: library.databaseURL, networkReaders: nil)
    watcher.start(folders: [library.folder], pausePollingDuringPlayback: true)
    defer { watcher.stop() }

    let index = try library.index()
    #expect(try await eventually(within: 20) { try index.trackCount() == library.readableCount })

    let file = library.manifest.files.first { $0.malformation == nil }!
    let source = library.path(file)
    let copy = (source as NSString).deletingLastPathComponent + "/copied in.flac"
    try FileManager.default.copyItem(atPath: source, toPath: copy)
    #expect(
        try await eventually(within: 20) { try index.trackCount() == library.readableCount + 1 })
}

@Test func aRootWithATrailingSlashIndexesEachFileOnce() async throws {
    let library = try TestLibrary()
    let watcher = LibraryWatcher(databaseURL: library.databaseURL, networkReaders: nil)
    watcher.start(
        folders: [WatchedFolder(path: library.root + "/", kind: .local)],
        pausePollingDuringPlayback: true)
    defer { watcher.stop() }

    let index = try library.index()
    #expect(try await eventually(within: 20) { try index.trackCount() == library.readableCount })
    let file = library.manifest.files.first { $0.malformation == nil }!
    let source = library.path(file)
    let copy = (source as NSString).deletingLastPathComponent + "/copied in.flac"
    try FileManager.default.copyItem(atPath: source, toPath: copy)
    #expect(
        try await eventually(within: 20) { try index.trackCount() == library.readableCount + 1 })
    // Let the rescan finish, then check that it stored only the paths the folder spells.
    try await Task.sleep(nanoseconds: 3_000_000_000)
    #expect(try index.trackCount() == library.readableCount + 1)
    let doubled = try index.database.prepare("SELECT path FROM files WHERE path LIKE '%//%'")
        .map { try $0.text(0) }
    #expect(doubled.isEmpty)
}

@Test func reportsEachScansOutcome() async throws {
    let library = try TestLibrary()
    let received = LockedEvents()
    let watcher = LibraryWatcher(
        databaseURL: library.databaseURL, networkReaders: nil, events: received.append)
    watcher.start(
        folders: [library.folder, WatchedFolder(path: library.root + "-gone", kind: .local)],
        pausePollingDuringPlayback: true)
    defer { watcher.stop() }

    #expect(try await eventually(within: 20) { received.scanned.count == 2 })
    let byFolder = Dictionary(uniqueKeysWithValues: received.scanned)
    #expect(byFolder[library.root]?.read == library.manifest.files.count)
    #expect(byFolder[library.root + "-gone"]?.issues.map(\.kind) == [.rootUnavailable])
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WatcherEvent] = []

    func append(_ event: WatcherEvent) { lock.withLock { events.append(event) } }

    var scanned: [(String, ScanSummary)] {
        lock.withLock {
            events.compactMap { event in
                guard case .scanned(let folder, let summary) = event else { return nil }
                return (folder, summary)
            }
        }
    }
}
