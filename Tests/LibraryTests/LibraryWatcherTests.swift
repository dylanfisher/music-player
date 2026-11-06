import Foundation
import Metadata
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
    watcher.start(
        folders: [library.folder], rescanNetworkFoldersAtLaunch: false,
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
}

@Test func aRootWithATrailingSlashIndexesEachFileOnce() async throws {
    let library = try TestLibrary()
    let watcher = LibraryWatcher(databaseURL: library.databaseURL, networkReaders: nil)
    watcher.start(
        folders: [WatchedFolder(path: library.root + "/", kind: .local)],
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
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
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
    defer { watcher.stop() }

    #expect(try await eventually(within: 20) { received.scanned.count == 2 })
    let byFolder = Dictionary(uniqueKeysWithValues: received.scanned)
    #expect(byFolder[library.root]?.read == library.manifest.files.count)
    #expect(byFolder[library.root + "-gone"]?.issues.map(\.kind) == [.rootUnavailable])
    watcher.stop()

    // Watching nothing removes nothing, since a lost or default config gives that (ADR 0082)...
    let next = LibraryWatcher(
        databaseURL: library.databaseURL, networkReaders: nil, events: received.append)
    next.start(folders: [], rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
    defer { next.stop() }
    #expect(try await eventually(within: 20) { received.launchesEnded == 2 })
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(received.removed.isEmpty)
    #expect(try library.index().trackCount() > 0)
    // ...but Stop Watching on the last folder removes what it held.
    next.removeEveryFile()
    #expect(try await eventually(within: 20) { received.removed == [library.manifest.files.count] })
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WatcherEvent] = []

    func append(_ event: WatcherEvent) { lock.withLock { events.append(event) } }

    var edited: [ScanSummary] {
        lock.withLock {
            events.compactMap { event in
                guard case .edited(let summary) = event else { return nil }
                return summary
            }
        }
    }

    var removed: [Int] {
        lock.withLock {
            events.compactMap { event in
                guard case .removed(let count) = event else { return nil }
                return count
            }
        }
    }

    var folders: [[WatchedFolder]] {
        lock.withLock {
            events.compactMap { event in
                guard case .folders(let folders) = event else { return nil }
                return folders
            }
        }
    }

    /// The folder of each scan that failed, in order.
    var failedScans: [String] {
        lock.withLock {
            events.compactMap { event in
                guard case .scanFailed(let folder, _) = event else { return nil }
                return folder
            }
        }
    }

    var launchesEnded: Int {
        lock.withLock {
            events.filter { event in
                if case .launchScansEnded = event { return true }
                return false
            }.count
        }
    }

    var kept: [String] {
        lock.withLock {
            events.compactMap { event in
                guard case .keptIndex(let folder) = event else { return nil }
                return folder
            }
        }
    }

    var scanned: [(String, ScanSummary)] {
        lock.withLock {
            events.compactMap { event in
                guard case .scanned(let folder, let summary) = event else { return nil }
                return (folder, summary)
            }
        }
    }
}

@Test func aRescanOfEditedFoldersReachesANetworkFolder() async throws {
    let library = try TestLibrary()
    let network = WatchedFolder(path: library.root, kind: .network, pollIntervalMinutes: 60)
    let watcher = LibraryWatcher(databaseURL: library.databaseURL, networkReaders: 4)
    watcher.start(
        folders: [network], rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
    defer { watcher.stop() }

    let index = try library.index()
    #expect(try await eventually(within: 20) { try index.trackCount() == library.readableCount })
    let file = library.manifest.files.first { $0.malformation == nil }!
    let folder = (library.path(file) as NSString).deletingLastPathComponent
    try FileManager.default.copyItem(atPath: library.path(file), toPath: folder + "/copied in.flac")
    // No poll is due for an hour and FSEvents doesn't watch a network folder.
    try await Task.sleep(nanoseconds: 3_000_000_000)
    #expect(try index.trackCount() == library.readableCount)
    watcher.rescan(directories: [folder])
    #expect(
        try await eventually(within: 20) { try index.trackCount() == library.readableCount + 1 })
}

@Test func aShareMountedSomewhereNewIsRewrittenThenScanned() async throws {
    let library = try TestLibrary()
    // A folder stands in for the share's mount point, with the library inside it.
    let mountPoint = (library.root as NSString).deletingLastPathComponent + "/nas-music"
    try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: library.root, toPath: mountPoint + "/library")
    let mounts = FakeMounts([MountedShare(url: "smb://nas/music", mountPoint: mountPoint)])
    let received = LockedEvents()
    let watcher = LibraryWatcher(
        databaseURL: library.databaseURL, networkReaders: 4, mounts: mounts,
        events: received.append)
    watcher.start(
        folders: [WatchedFolder(path: "library", share: "smb://nas/music", kind: .network)],
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: false)
    defer { watcher.stop() }
    #expect(try await eventually(within: 20) { received.scanned.count == 1 })
    let first = canonicalPath(mountPoint + "/library")
    #expect(received.folders.last == [WatchedFolder(path: first, kind: .network)])
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let index = try library.index()
    try index.recordPlay(first + "/" + file.path, at: 100)
    let id = try #require(try index.track(path: first + "/" + file.path)).id

    // Ejected and mounted again at "-1", with the old mount point left behind empty.
    try FileManager.default.moveItem(atPath: mountPoint, toPath: mountPoint + "-1")
    try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
    mounts.set([MountedShare(url: "smb://nas/music", mountPoint: mountPoint + "-1")])
    watcher.sharesMayHaveMoved()
    #expect(try await eventually(within: 20) { received.scanned.count == 2 })
    let moved = canonicalPath(mountPoint + "-1/library")
    #expect(received.folders.last == [WatchedFolder(path: moved, kind: .network)])
    let rescan = try #require(received.scanned.last)
    #expect(rescan.0 == moved)
    #expect(rescan.1.read == 0, "the rewrite left nothing to read again")
    #expect(rescan.1.removed == 0)
    #expect(rescan.1.unchanged == library.manifest.files.count)
    let after = try #require(try index.track(path: moved + "/" + file.path))
    #expect(after.id == id)
    #expect(after.playCount == 1)
}

@Test func aListingThatFailsAtStartStillWatchesTheRestAndTriesAgain() async throws {
    struct Refused: Error {}
    let library = try TestLibrary()
    let mountPoint = (library.root as NSString).deletingLastPathComponent + "/nas-music"
    try FileManager.default.createDirectory(
        atPath: mountPoint + "/library", withIntermediateDirectories: true)
    let mounts = FakeMounts([MountedShare(url: "smb://nas/music", mountPoint: mountPoint)])
    mounts.fail(with: Refused())
    let received = LockedEvents()
    let watcher = LibraryWatcher(
        databaseURL: library.databaseURL, networkReaders: 4, mounts: mounts,
        events: received.append)
    let share = WatchedFolder(path: "library", share: "smb://nas/music", kind: .network)
    watcher.start(
        folders: [library.folder, share], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: false)
    defer { watcher.stop() }
    // The local folder is scanned; the share folder, never found, is offline.
    #expect(try await eventually(within: 20) { received.scanned.count == 2 })
    let byFolder = Dictionary(uniqueKeysWithValues: received.scanned)
    #expect(byFolder[library.root]?.read == library.manifest.files.count)
    #expect(byFolder["smb://nas/music/library"]?.issues.map(\.kind) == [.rootUnavailable])

    mounts.fail(with: nil)
    watcher.sharesMayHaveMoved()
    let found = canonicalPath(mountPoint + "/library")
    #expect(try await eventually(within: 20) { received.scanned.contains { $0.0 == found } })
}

/// The file system, as a network volume, with each directory a scan lists recorded.
private final class ListingRecorder: ScanFileAccess, @unchecked Sendable {
    private let system = SystemFileAccess()
    private let lock = NSLock()
    private var listed: [String] = []

    var directories: [String] { lock.withLock { listed } }

    func volumeIsLocal(_ path: String) throws -> Bool? { false }

    func contentsOfDirectory(_ directory: String, keys: [URLResourceKey]) throws -> [URL] {
        lock.withLock { listed.append(directory) }
        return try system.contentsOfDirectory(directory, keys: keys)
    }

    func readMetadata(at path: String) throws(MetadataError) -> ParsedFile {
        try system.readMetadata(at: path)
    }
}

private func watcher(
    _ library: TestLibrary, through access: any ScanFileAccess,
    events: @escaping @Sendable (WatcherEvent) -> Void
) -> LibraryWatcher {
    LibraryWatcher(
        scanner: LibraryScanner(
            databaseURL: library.databaseURL, networkReaders: 1, access: access),
        mounts: FakeMounts(), events: events)
}

@Test func aNetworkFolderTheIndexHoldsIsntWalkedAtLaunchButANewOneIs() async throws {
    let library = try TestLibrary()
    let network = WatchedFolder(path: library.root, kind: .network)
    _ = try library.scan(network)
    // A second folder, never scanned, beside the first.
    let added = library.root + "-added"
    try FileManager.default.createDirectory(atPath: added, withIntermediateDirectories: true)
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    try FileManager.default.copyItem(atPath: library.path(file), toPath: added + "/added.flac")
    let access = ListingRecorder()
    let received = LockedEvents()
    let watcher = watcher(library, through: access, events: received.append)
    watcher.start(
        folders: [network, WatchedFolder(path: added, kind: .network)],
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: false)
    defer { watcher.stop() }

    #expect(try await eventually(within: 20) { received.scanned.count == 1 })
    #expect(received.scanned.map(\.0) == [added])
    #expect(received.kept == [library.root])
    // Long enough for a walk of the first folder to have begun, had one been started.
    try await Task.sleep(nanoseconds: 2_000_000_000)
    #expect(received.scanned.count == 1)
    #expect(access.directories.allSatisfy { $0 == added || isPath($0, under: added) })
    #expect(received.launchesEnded == 1)
}

@Test func theSettingWalksANetworkFolderTheIndexHoldsAtLaunch() async throws {
    let library = try TestLibrary()
    let network = WatchedFolder(path: library.root, kind: .network)
    _ = try library.scan(network)
    let access = ListingRecorder()
    let received = LockedEvents()
    let watcher = watcher(library, through: access, events: received.append)
    watcher.start(
        folders: [network], rescanNetworkFoldersAtLaunch: true, pausePollingDuringPlayback: false)
    defer { watcher.stop() }

    #expect(try await eventually(within: 20) { received.scanned.count == 1 })
    #expect(received.kept.isEmpty)
    #expect(access.directories.contains(library.root))
}

/// The file system, as a network volume, where reading holds after the first `readsBeforeGate`
/// files until `open`, so a test can act while a scan is surely under way.
private final class GatedAccess: ScanFileAccess, @unchecked Sendable {
    private let system = SystemFileAccess()
    private let condition = NSCondition()
    private let readsBeforeGate: Int
    // Guarded by `condition`.
    private var reads = 0
    private var isOpen = false

    init(readsBeforeGate: Int) { self.readsBeforeGate = readsBeforeGate }

    /// Whether a reader is waiting at the gate.
    var isHeld: Bool { condition.withLock { reads > readsBeforeGate && !isOpen } }

    func open() {
        condition.withLock {
            isOpen = true
            condition.broadcast()
        }
    }

    func volumeIsLocal(_ path: String) throws -> Bool? { false }

    func contentsOfDirectory(_ directory: String, keys: [URLResourceKey]) throws -> [URL] {
        try system.contentsOfDirectory(directory, keys: keys)
    }

    func readMetadata(at path: String) throws(MetadataError) -> ParsedFile {
        condition.withLock {
            reads += 1
            while reads > readsBeforeGate && !isOpen { condition.wait() }
        }
        return try system.readMetadata(at: path)
    }
}

@Test func aRunningPollPausesForPlaybackAndFinishesWithoutStartingOver() async throws {
    let library = try TestLibrary()
    let access = GatedAccess(readsBeforeGate: 20)
    let received = LockedEvents()
    let watcher = LibraryWatcher(
        scanner: LibraryScanner(
            databaseURL: library.databaseURL, networkReaders: 4, access: access, batchSize: 1),
        mounts: FakeMounts(), events: received.append)
    watcher.start(
        folders: [WatchedFolder(path: library.root, kind: .network)],
        rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
    defer { watcher.stop() }
    #expect(try await eventually(within: 20) { access.isHeld })

    watcher.playbackChanged(.playing, pausePollingDuringPlayback: true)
    // The watcher's queue applies the pause before the gate opens.
    try await Task.sleep(nanoseconds: 500_000_000)
    access.open()
    // The files being read when it paused are stored; then nothing more.
    try await Task.sleep(nanoseconds: 500_000_000)
    let index = try library.index()
    let paused = try index.trackCount()
    try await Task.sleep(nanoseconds: 1_500_000_000)
    #expect(try index.trackCount() == paused)
    #expect(paused < library.readableCount)
    #expect(received.scanned.isEmpty)

    watcher.playbackChanged(.stopped, pausePollingDuringPlayback: true)
    #expect(try await eventually(within: 30) { received.scanned.count == 1 })
    #expect(try index.trackCount() == library.readableCount)
    // One pass read each file once: it went on from where it paused.
    #expect(received.scanned.first?.1.read == library.manifest.files.count)
}

/// Every scan that fails says so, not only the first of a run of them, so the window stops
/// showing it as running.
@Test func eachScanThatFailsInARowReportsItsEnd() async throws {
    let library = try TestLibrary()
    // A database in a folder that can't be written fails every scan as it opens.
    let locked = library.databaseURL.deletingLastPathComponent().appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: locked.path)
    }
    let received = LockedEvents()
    let watcher = LibraryWatcher(
        databaseURL: locked.appendingPathComponent("library.sqlite"), networkReaders: nil,
        events: received.append)
    watcher.start(
        folders: [library.folder], rescanNetworkFoldersAtLaunch: false,
        pausePollingDuringPlayback: true)
    defer { watcher.stop() }
    // The first failure finding the shares names no folder.
    func failures() -> Int { received.failedScans.filter { $0 == library.root }.count }
    #expect(try await eventually(within: 20) { failures() == 1 })
    watcher.rescanNow()
    #expect(try await eventually(within: 20) { failures() == 2 })
}

@Test func rescanNowWalksANetworkFolderWhilePollsArePausedForPlayback() async throws {
    let library = try TestLibrary()
    let network = WatchedFolder(path: library.root, kind: .network)
    _ = try library.scan(network)
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let folder = (library.path(file) as NSString).deletingLastPathComponent
    try FileManager.default.copyItem(atPath: library.path(file), toPath: folder + "/copied in.flac")
    let received = LockedEvents()
    let watcher = watcher(library, through: ListingRecorder(), events: received.append)
    watcher.start(
        folders: [network], rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
    defer { watcher.stop() }
    watcher.playbackChanged(.playing, pausePollingDuringPlayback: true)
    #expect(try await eventually(within: 20) { received.kept == [library.root] })

    watcher.rescanNow()
    let index = try library.index()
    #expect(
        try await eventually(within: 20) { try index.trackCount() == library.readableCount + 1 })
    #expect(try await eventually(within: 20) { received.scanned.count == 1 })
}

/// The tag editor's files are read at once in a network folder whose polls wait for playback,
/// while the folder's own rescan still waits.
@Test func editedFilesAreReadAtOnceWhilePollsArePausedForPlayback() async throws {
    let library = try TestLibrary()
    let network = WatchedFolder(path: library.root, kind: .network)
    _ = try library.scan(network)
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let path = library.path(file)
    let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path, isDirectory: false))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(count: 16))
    try handle.close()
    let received = LockedEvents()
    let watcher = watcher(library, through: ListingRecorder(), events: received.append)
    watcher.start(
        folders: [network], rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
    defer { watcher.stop() }
    watcher.playbackChanged(.playing, pausePollingDuringPlayback: true)
    #expect(try await eventually(within: 20) { received.kept == [library.root] })

    watcher.rescan(files: [path])
    #expect(try await eventually(within: 5) { received.edited.map(\.read) == [1] })
    let index = try library.index()
    #expect(try index.knownFile(at: path)?.sizeBytes == size + 16)
    #expect(received.scanned.isEmpty, "the folder's rescan waits for playback")
}

@Test func rescanWalksTheChosenFolderAsSettingsHasIt() async throws {
    let library = try TestLibrary()
    let network = WatchedFolder(path: library.root, kind: .network)
    _ = try library.scan(network)
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let folder = (library.path(file) as NSString).deletingLastPathComponent
    try FileManager.default.copyItem(atPath: library.path(file), toPath: folder + "/copied in.flac")
    let received = LockedEvents()
    let watcher = watcher(library, through: ListingRecorder(), events: received.append)
    watcher.start(
        folders: [network], rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: true)
    defer { watcher.stop() }
    watcher.playbackChanged(.playing, pausePollingDuringPlayback: true)
    #expect(try await eventually(within: 20) { received.kept == [library.root] })

    watcher.rescan(folders: [WatchedFolder(path: "/Volumes/gone", kind: .network), network])
    let index = try library.index()
    #expect(
        try await eventually(within: 20) { try index.trackCount() == library.readableCount + 1 })
    #expect(try await eventually(within: 20) { received.scanned.count == 1 })
}

@Test func aFirstScanCutShortIsScannedAgainAtLaunch() async throws {
    let library = try TestLibrary()
    let network = WatchedFolder(path: library.root, kind: .network)
    let access = GatedAccess(readsBeforeGate: 20)
    let control = ScanControl()
    let scanner = LibraryScanner(
        databaseURL: library.databaseURL, networkReaders: 4, access: access, batchSize: 1)
    let cut = Task.detached { try scanner.scan(network, control: control) }
    #expect(try await eventually(within: 20) { access.isHeld })
    control.cancel()
    access.open()
    #expect(try await cut.value.cancelled)
    #expect(try library.index().trackCount() > 0, "the cut scan stored some files")

    let received = LockedEvents()
    let watcher = watcher(library, through: ListingRecorder(), events: received.append)
    watcher.start(
        folders: [network], rescanNetworkFoldersAtLaunch: false, pausePollingDuringPlayback: false)
    defer { watcher.stop() }
    #expect(try await eventually(within: 20) { received.scanned.count == 1 })
    #expect(received.kept.isEmpty)
    #expect(try library.index().trackCount() == library.readableCount)
    #expect(received.launchesEnded == 1)
}
