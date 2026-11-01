import Foundation
import SQLite3
import Testing

@testable import Fixtures
@testable import Library
@testable import Metadata
@testable import SQLite
@testable import Settings

@Test func indexesEveryFileAndStoresEachProblem() throws {
    let library = try TestLibrary()
    let summary = try library.scan()
    #expect(summary.read == library.manifest.files.count)
    #expect(summary.failed == library.unreadableFiles.count)
    #expect(summary.unchanged == 0)
    #expect(summary.otherFiles == 1, "manifest.json")
    #expect(summary.issues.isEmpty)

    let index = try library.index()
    #expect(try index.trackCount() == library.readableCount)
    let issues = try index.fileIssues()
    let failures = issues.filter { if case .failure = $0.problem { true } else { false } }
    #expect(Set(failures.map(\.path)) == Set(library.unreadableFiles.map(library.path)))
    let warned = library.manifest.files.first { $0.malformation == .unreadableTrackNumber }!
    #expect(
        issues.contains { $0.path == library.path(warned) && $0.problem == .warning(.badNumber) })
}

@Test func rescanWithNoChangesReadsNothing() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let again = try library.scan()
    #expect(again.read == 0)
    #expect(again.removed == 0)
    #expect(again.unchanged == library.manifest.files.count)
}

@Test func rescanReadsChangedFilesAndRemovesDeletedOnes() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let files = library.manifest.files.filter { $0.malformation == nil }
    let changed = try FileHandle(forWritingTo: URL(fileURLWithPath: library.path(files[0])))
    try changed.seekToEnd()
    try changed.write(contentsOf: Data(count: 16))
    try changed.close()
    try FileManager.default.removeItem(atPath: library.path(files[1]))

    let summary = try library.scan()
    #expect(summary.read == 1)
    #expect(summary.removed == 1)
    #expect(try library.index().trackCount() == library.readableCount - 1)
}

@Test func missingFolderRemovesNothing() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    try FileManager.default.moveItem(atPath: library.root, toPath: library.root + " (away)")
    let summary = try library.scan()
    #expect(summary.issues.map(\.kind) == [.rootUnavailable])
    #expect(summary.removed == 0)
    #expect(try library.index().trackCount() == library.readableCount)
}

@Test func emptyMountPointRemovesNothing() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    try FileManager.default.moveItem(atPath: library.root, toPath: library.root + " (away)")
    try FileManager.default.createDirectory(
        atPath: library.root, withIntermediateDirectories: false)
    let summary = try library.scan()
    #expect(summary.issues.map(\.kind) == [.rootEmpty])
    #expect(try library.index().trackCount() == library.readableCount)
}

@Test func unreadableDirectoryKeepsItsFiles() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let file = library.manifest.files.first { $0.malformation == nil }!
    let directory = (library.path(file) as NSString).deletingLastPathComponent
    let inside = library.manifest.files.filter {
        ($0.path as NSString).deletingLastPathComponent
            == (file.path as NSString).deletingLastPathComponent
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory)
    }
    let summary = try library.scan()
    #expect(summary.issues.map(\.kind) == [.unreadable])
    #expect(summary.issues.first?.path == directory)
    #expect(summary.removed == 0)
    #expect(summary.unchanged == library.manifest.files.count - inside.count)
}

@Test func excludedFilesLeaveTheIndex() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    var folder = library.folder
    folder.exclude = ["*.flac"]
    let flacs = library.manifest.files.filter { $0.path.hasSuffix(".flac") }
    let summary = try library.scan(folder)
    #expect(summary.removed == flacs.count)
    #expect(summary.read == 0)

    folder.exclude = []
    folder.include = ["*.mp3"]
    let mp3s = library.manifest.files.filter { $0.path.hasSuffix(".mp3") }
    let only = try library.scan(folder)
    #expect(only.unchanged == mp3s.count)
    #expect(
        try library.index().fileIssues().allSatisfy { $0.path.hasSuffix(".mp3") })
}

@Test func subtreeScanReadsOnlyThatSubtree() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let file = library.manifest.files.first { $0.malformation == nil }!
    let source = library.path(file)
    let directory = (source as NSString).deletingLastPathComponent
    try FileManager.default.copyItem(atPath: source, toPath: directory + "/copy.flac")
    let summary = try library.scan(only: [directory])
    #expect(summary.read == 1)
    #expect(
        summary.unchanged
            == library.manifest.files.filter {
                ($0.path as NSString).deletingLastPathComponent
                    == (file.path as NSString).deletingLastPathComponent
            }.count)

    // A deleted folder is looked for from its parent, which finds its files gone.
    try FileManager.default.removeItem(atPath: directory)
    let removed = try library.scan(only: [directory])
    #expect(removed.removed == summary.unchanged + 1)
    #expect(removed.issues.isEmpty)
}

@Test func pausedScanWaitsAndCancelledScanRemovesNothing() async throws {
    let library = try TestLibrary()
    let control = ScanControl()
    control.pause()
    let (stream, continuation) = ScanProgress.makeStream()
    let scanner = library.scanner
    let folder = library.folder
    let scan = Task.detached {
        try scanner.scan(folder, control: control, progress: continuation)
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(try library.index().trackCount() == 0)
    control.resume()
    let summary = try await scan.value
    #expect(summary.read == library.manifest.files.count)
    continuation.finish()
    // Only the newest value is buffered, and it's the finished count.
    var last: ScanProgress?
    for await progress in stream { last = progress }
    #expect(last?.read == library.manifest.files.count)
    #expect(last?.stage == .reading)

    try FileManager.default.removeItem(atPath: library.path(library.manifest.files[0]))
    let cancelled = ScanControl()
    cancelled.cancel()
    let stopped = try library.scan(control: cancelled)
    #expect(stopped.cancelled)
    #expect(stopped.removed == 0)
}

/// Reads fail with an I/O error, as on a NAS that went away.
private struct FailingReads: ScanFileAccess {
    func volumeIsLocal(_ path: String) throws -> Bool? { true }

    func contentsOfDirectory(_ directory: String, keys: [URLResourceKey]) throws -> [URL] {
        try SystemFileAccess().contentsOfDirectory(directory, keys: keys)
    }

    func readMetadata(at path: String) throws(MetadataError) -> ParsedFile {
        throw MetadataError(path: path, kind: .unreadable, offset: nil, detail: "EIO")
    }
}

@Test func lostRootStopsReadingAndStoresNothing() throws {
    let library = try TestLibrary()
    let index = try library.index()
    let pipeline = ScanPipeline(
        [library.root], root: library.root, filter: FolderFilter(include: [], exclude: []),
        known: [:], index: index, controller: nil, readers: 2, access: FailingReads(),
        control: ScanControl(), counter: ProgressCounter(nil), rootIsThere: { false })
    let outcome = try pipeline.run()
    #expect(outcome.rootLost)
    #expect(outcome.read == 0)
    #expect(try index.fileIssues().isEmpty)
}

@Test func unreadableFileKeepsItsEarlierTrackAndIsReadAgain() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let file = library.manifest.files.first { $0.malformation == nil }!
    let index = try library.index()
    let known = try #require(try index.knownFiles(under: library.root)[library.path(file)])
    try index.store([
        ScannedFile(
            path: library.path(file), sizeBytes: known.sizeBytes,
            modifiedSeconds: known.modifiedSeconds, known: known,
            outcome: .failure(
                MetadataError(
                    path: library.path(file), kind: .unreadable, offset: nil, detail: "EIO")))
    ])
    #expect(try index.trackCount() == library.readableCount)
    #expect(try index.fileIssues().contains { $0.problem == .failure(.unreadable) })

    let summary = try library.scan()
    #expect(summary.read == 1)
    #expect(try !index.fileIssues().contains { $0.problem == .failure(.unreadable) })
}

@Test func removesFilesOutsideTheWatchedFolders() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    #expect(try index.removeFiles(outside: [library.root]) == 0)
    #expect(try index.removeFiles(outside: ["/Volumes/Elsewhere"]) == library.manifest.files.count)
    #expect(try index.trackCount() == 0)
}

@Test func patternsMatchComponentsAndAnyDepth() {
    #expect(PathPattern("*.flac").matches("A/B/x.flac"))
    #expect(!PathPattern("*.flac").matches("A/x.mp3"))
    #expect(PathPattern("Scans").matches("Artist/Album/Scans"))
    #expect(PathPattern("**/Scans/**").matches("Artist/Album/Scans"))
    #expect(PathPattern("**/Scans/**").matches("Scans/front.jpg"))
    #expect(PathPattern("Artist/*/0?.flac").matches("Artist/Album/01.flac"))
    #expect(!PathPattern("Artist/*/0?.flac").matches("Artist/Album/Disc 1/01.flac"))
    #expect(PathPattern("Artist/**/*.flac").matches("Artist/Album/Disc 1/01.flac"))
    #expect(!PathPattern("Artist/**").matches("Other/01.flac"))
    #expect(!PathPattern("").matches("x.flac"))

    let filter = FolderFilter(include: ["*.flac"], exclude: ["**/Live/**"])
    #expect(filter.includesFile("A/1.flac"))
    #expect(!filter.includesFile("A/1.mp3"))
    #expect(!filter.includesFile("A/Live/1.flac"))
    #expect(!filter.includesDirectory("A/Live"))
    #expect(filter.includesDirectory("A/Studio"))
}

@Test func skipsHiddenFilesAndReportsSymbolicLinks() throws {
    let library = try TestLibrary()
    let file = library.manifest.files.first { $0.malformation == nil }!
    let directory = (library.path(file) as NSString).deletingLastPathComponent
    // The AppleDouble file macOS writes beside each file on an SMB share.
    try Data(count: 4096).write(to: URL(fileURLWithPath: directory + "/._copy.flac"))
    try FileManager.default.createSymbolicLink(
        atPath: library.root + "/Linked", withDestinationPath: directory)
    let summary = try library.scan()
    #expect(summary.read == library.manifest.files.count)
    #expect(
        summary.issues == [
            ScanIssue(kind: .symbolicLink, path: library.root + "/Linked", detail: "not followed")
        ])
}

@Test func emptyRootRemovesNothingOnASubtreeScanOfTheRoot() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    try FileManager.default.moveItem(atPath: library.root, toPath: library.root + " (away)")
    try FileManager.default.createDirectory(
        atPath: library.root, withIntermediateDirectories: false)
    let summary = try library.scan(only: [library.root])
    #expect(summary.issues.map(\.kind) == [.rootEmpty])
    #expect(try library.index().trackCount() == library.readableCount)
}

@Test func folderRenamedOnlyInCaseIsIndexedUnderItsNewSpellingOnly() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let file = library.manifest.files.first { $0.malformation == nil }!
    let directory = (library.path(file) as NSString).deletingLastPathComponent
    let renamed =
        (directory as NSString).deletingLastPathComponent + "/"
        + (directory as NSString).lastPathComponent.uppercased()
    try #require(renamed != directory)
    try FileManager.default.moveItem(atPath: directory, toPath: renamed)
    // FSEvents reports both spellings, and a case-insensitive volume finds the folder by either.
    _ = try library.scan(only: [directory, renamed])
    let paths = try library.index().database.prepare("SELECT path FROM files").map {
        try $0.text(0)
    }
    #expect(paths.count == library.manifest.files.count)
    #expect(!paths.contains { isPath($0, under: directory) })
    #expect(paths.contains { isPath($0, under: renamed) })
}

@Test func changesInsideAnExcludedFolderDoNotIndexIt() throws {
    let library = try TestLibrary()
    let file = library.manifest.files.first { $0.malformation == nil }!
    let directory = (library.path(file) as NSString).deletingLastPathComponent
    let relative = String(directory.dropFirst(library.root.count + 1))
    var folder = library.folder
    folder.exclude = [relative]
    _ = try library.scan(folder)
    let before = try library.index().trackCount()
    try FileManager.default.copyItem(
        atPath: library.path(file), toPath: directory + "/copy.flac")
    let summary = try library.scan(folder, only: [directory])
    #expect(summary.read == 0)
    #expect(try library.index().trackCount() == before)
}

@Test func cachedIDsDeletedByAnotherScanAreReloaded() throws {
    let library = try TestLibrary()
    let tagged = try library.manifest.files.filter { $0.malformation == nil }.compactMap {
        file -> (String, ParsedFile)? in
        let parsed = try readMetadata(at: URL(fileURLWithPath: library.path(file)))
        return parsed.metadata.tags.artist == nil ? nil : (library.path(file), parsed)
    }.first
    let (path, parsed) = try #require(tagged)
    func scanned(_ path: String) -> ScannedFile {
        ScannedFile(
            path: path, sizeBytes: 1, modifiedSeconds: 0, known: nil, outcome: .success(parsed))
    }
    let index = try library.index()
    try index.store([scanned(path)])

    // The other scan removes the file and the artist, album and genre only it used.
    let other = try library.index()
    try other.remove(Array(try other.knownFiles(under: library.root).values.map(\.id)))
    try other.deleteOrphans()

    try index.store([scanned(path + ".copy")])
    #expect(try index.trackCount() == 1)
}

@Test func rootSpelledPrecomposedOrDecomposedIsOneFolder() throws {
    let library = try TestLibrary()
    let precomposed = (library.root as NSString).deletingLastPathComponent + "/Caf\u{e9}"
    try FileManager.default.moveItem(atPath: library.root, toPath: precomposed)
    let decomposed = precomposed.decomposedStringWithCanonicalMapping
    #expect(Array(precomposed.utf8) != Array(decomposed.utf8))

    let first = try library.scan(WatchedFolder(path: precomposed, kind: .local))
    #expect(first.read == library.manifest.files.count)
    let again = try library.scan(WatchedFolder(path: decomposed, kind: .local))
    #expect(again.read == 0)
    #expect(again.removed == 0)
    let index = try library.index()
    #expect(try index.trackCount() == library.readableCount)
    let paths = try index.database.prepare("SELECT path FROM files").map { try $0.text(0) }
    #expect(paths.allSatisfy { Array($0.utf8).starts(with: Array(decomposed.utf8)) })
    #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
}

@Test func onlyWatchedFoldersMayBeScannedIntoTheAppIndex() throws {
    let folders = [WatchedFolder(path: "/Volumes/Music/", kind: .network)]
    try requireWatched("/Volumes/Music", in: folders)
    #expect(throws: LibraryError.notWatched("/Volumes/Other")) {
        try requireWatched("/Volumes/Other", in: folders)
    }
    #expect(
        LibraryError.notWatched("/x").description
            == "/x isn't a watched folder; add it in settings,"
            + " or pass --db <file> to scan into a separate index")
}

@Test func aNASThatDropsMidScanKeepsEveryTrack() throws {
    let library = try TestLibrary()
    let nas = SimulatedNAS(operationSeconds: 0, listingSeconds: 0, capacity: 4, fileDelay: nil)
    let scanner = LibraryScanner(databaseURL: library.databaseURL, networkReaders: 2, access: nas)
    let folder = WatchedFolder(path: library.root, kind: .network)
    _ = try scanner.scan(folder)
    let index = try library.index()
    let before = try index.trackIDs(TrackFilter(), sortedBy: .title)
    // Every file changed, so the rescan reads each one, and the NAS drops partway through.
    for file in library.manifest.files where file.malformation == nil {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: library.path(file)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 16))
        try handle.close()
    }
    nas.drop(afterOperations: 12)

    let dropped = try scanner.scan(folder)
    #expect(dropped.removed == 0)
    #expect(try index.trackIDs(TrackFilter(), sortedBy: .title) == before)
    let unreadable = try index.fileIssues().filter { $0.problem == .failure(.unreadable) }
    #expect(!unreadable.isEmpty || dropped.issues.contains { $0.kind == .unreadable })

    nas.reconnect()
    let back = try scanner.scan(folder)
    #expect(back.removed == 0)
    #expect(back.issues.isEmpty)
    #expect(try index.trackCount() == library.readableCount)
    #expect(try !index.fileIssues().contains { $0.problem == .failure(.unreadable) })
}

@Test func aFullDatabaseFailsTheScanAndKeepsTheIndex() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let before = try index.trackIDs(TrackFilter(), sortedBy: .title)
    let issues = try index.fileIssues()
    for file in library.manifest.files where file.malformation == nil {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: library.path(file)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 16))
        try handle.close()
    }
    // No more pages than it has: SQLITE_FULL, as on a full disk.
    let pages = try index.database.prepare("PRAGMA page_count").map { try $0.int(0) }[0]
    try index.database.execute("PRAGMA max_page_count = \(pages)")
    let pipeline = ScanPipeline(
        [library.root], root: library.root, filter: FolderFilter(include: [], exclude: []),
        known: try index.knownFiles(under: library.root), index: index, controller: nil,
        readers: 2, access: SystemFileAccess(), control: ScanControl(),
        counter: ProgressCounter(nil), rootIsThere: { true })
    #expect {
        try pipeline.run()
    } throws: { error in
        ((error as? SQLiteError)?.code ?? 0) & 0xFF == SQLITE_FULL
    }
    #expect(try index.trackIDs(TrackFilter(), sortedBy: .title) == before)
    #expect(try index.fileIssues() == issues)
    // With room again, the next scan stores every change.
    try index.database.execute("PRAGMA max_page_count = 1073741823")
    #expect(
        try library.scan().read == library.manifest.files.filter { $0.malformation == nil }.count)
}
