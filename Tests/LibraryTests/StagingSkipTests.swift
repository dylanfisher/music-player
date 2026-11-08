import Foundation
import Testing

@testable import Library
@testable import Settings

/// A library with a staged download inside it, as when the staging folder is found under a
/// watched folder: one stored by share and the other by path, so Settings couldn't compare them.
private func libraryWithStaging() throws -> (TestLibrary, staging: String, staged: String) {
    let library = try TestLibrary()
    let staging = library.root + "/staging"
    let job = staging + "/job-42"
    try FileManager.default.createDirectory(atPath: job, withIntermediateDirectories: true)
    let source = library.manifest.files.first { $0.malformation == nil }!
    let staged = job + "/01 First Song." + (source.path as NSString).pathExtension
    try FileManager.default.copyItem(atPath: library.path(source), toPath: staged)
    return (library, staging, staged)
}

@Test func aScanNeverReadsTheStagingFolder() throws {
    let (library, staging, staged) = try libraryWithStaging()
    let options = ScanOptions(skippedFolders: [staging])
    let summary = try library.scanner.scan(library.folder, options: options)
    #expect(summary.read == library.manifest.files.count)
    let paths = try library.index().knownFiles(under: library.root).keys
    #expect(!paths.contains { isPath($0, inOrAt: staging) }, "\(staged)")
    #expect(summary.issues.map(\.kind) == [.stagingFolderSkipped])

    // An FSEvents batch inside it starts a subtree scan there, which reads nothing either.
    let subtree = try library.scanner.scan(
        library.folder, only: [staging + "/job-42"], options: options)
    #expect(subtree.read == 0 && subtree.unchanged == 0)
    #expect(try library.index().knownFiles(under: staging).isEmpty)
}

@Test func aWatchedFolderInsideTheStagingFolderIsntScanned() throws {
    let (library, staging, _) = try libraryWithStaging()
    let summary = try library.scanner.scan(
        WatchedFolder(path: staging + "/job-42", kind: .local),
        options: ScanOptions(skippedFolders: [staging]))
    #expect(summary.read == 0)
    #expect(summary.issues.map(\.kind) == [.insideStagingFolder])
    #expect(try library.index().trackCount() == 0)
}

/// The watcher's events, as they come.
private final class StagingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WatcherEvent] = []

    func append(_ event: WatcherEvent) { lock.withLock { events.append(event) } }

    var scanned: [ScanSummary] {
        lock.withLock {
            events.compactMap { if case .scanned(_, let summary) = $0 { summary } else { nil } }
        }
    }

    var syncFailures: [String] {
        lock.withLock {
            events.compactMap { if case .syncFailed(let reason) = $0 { reason } else { nil } }
        }
    }
}

/// Polls `condition` every 100 ms, for up to `seconds` of those waits.
private func eventually(within seconds: Double, _ condition: () throws -> Bool) async throws
    -> Bool
{
    for _ in 0..<Int(seconds * 10) {
        if try condition() { return true }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return try condition()
}

@Test func theWatcherFindsTheStagingFolderAndNeverIndexesIt() async throws {
    let (library, staging, staged) = try libraryWithStaging()
    let events = StagingEvents()
    let watcher = LibraryWatcher(
        databaseURL: library.databaseURL, networkReaders: nil, events: events.append)
    watcher.start(
        folders: [library.folder], stagingFolder: StagingFolder(path: staging),
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
    defer { watcher.stop() }

    let index = try library.index()
    #expect(try await eventually(within: 20) { !events.scanned.isEmpty })
    #expect(events.scanned.first?.issues.map(\.kind) == [.stagingFolderSkipped])
    #expect(try index.trackCount() == library.readableCount)

    // A file the service stages later comes as an FSEvents batch, and stays out too. A file
    // added to the library after it marks the point by which the batches have been scanned.
    try FileManager.default.copyItem(atPath: staged, toPath: staging + "/job-42/02 Second.flac")
    let source = library.path(library.manifest.files.first { $0.malformation == nil }!)
    try FileManager.default.copyItem(
        atPath: source,
        toPath: (source as NSString).deletingLastPathComponent + "/copied in.flac")
    #expect(
        try await eventually(within: 20) { try index.trackCount() == library.readableCount + 1 })
    #expect(try index.knownFiles(under: staging).isEmpty)
}

@Test func aSyncFolderFoundInsideTheStagingFolderIsntSyncedThrough() async throws {
    // Beside the library, as on the NAS, so the sync folder isn't in a watched folder too.
    let library = try TestLibrary()
    let staging = (library.root as NSString).deletingLastPathComponent + "/staging"
    let sync = staging + "/music-player"
    try FileManager.default.createDirectory(atPath: sync, withIntermediateDirectories: true)
    let events = StagingEvents()
    let watcher = LibraryWatcher(
        databaseURL: library.databaseURL, networkReaders: nil, events: events.append)
    watcher.start(
        folders: [library.folder], syncFolder: SyncFolder(path: sync),
        stagingFolder: StagingFolder(path: staging), rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: true)
    defer { watcher.stop() }

    #expect(try await eventually(within: 20) { !events.syncFailures.isEmpty })
    #expect(events.syncFailures.first?.contains("staging folder") == true)
}

@Test func theStagingFolderOverlapsAFolderInsideOrAroundIt() {
    let folders = ["/Volumes/music/library", "/Volumes/music-player"]
    #expect(stagingOverlap("/Volumes/music/staging", folders) == nil)
    #expect(stagingOverlap("/Volumes/music/library/staging", folders) == "/Volumes/music/library")
    #expect(stagingOverlap("/Volumes/music", folders) == "/Volumes/music/library")
    #expect(stagingOverlap("/Volumes/music/library", folders) == "/Volumes/music/library")
}
