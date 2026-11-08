import Foundation
import SQLite
import Testing

@testable import Discogs
@testable import Fixtures

private let date = "20261101"
/// Compressed bytes between checkpoints: a checkpoint at every few deflate blocks.
private let smallCheckpointBytes = 4096
/// The stages an import can be stopped or killed in.
private let stages: [CatalogImportProgress.Stage] =
    DumpKind.allCases.map { .reading($0) } + [.indexing]

/// Words that compress about as the dumps' text does, `count` of them from `seed`, for the
/// elements the import passes over: they make the deflate blocks as short as the dumps' are.
private func noise(_ count: Int, seed: Int) -> String {
    var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1
    return (0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return String(state % 50_000, radix: 36)
    }.joined(separator: " ")
}

/// A set whose every file is several deflate blocks, so a stop or a crash lands inside it.
private func writeSet(_ folder: borrowing DumpFolder, date: String = date) throws {
    let labels = (1...3000).map {
        "<label><id>\($0)</id><name>Label \($0 * 7919 % 100_003)</name>"
            + "<profile>\(noise(12, seed: $0))</profile></label>\n"
    }
    let artists = (1...3000).map {
        "<artist><id>\($0)</id><name>Artist \($0 * 104_729 % 1_000_003)</name>"
            + "<profile>\(noise(12, seed: $0 + 10_000))</profile>"
            + "<namevariations><name>A. \($0 * 31 % 997)</name></namevariations></artist>\n"
    }
    let masters = (1...2000).map {
        #"<master id="\#($0)"><main_release>\#($0 * 2)</main_release><artists><artist><id>\#($0 % 997)</id><name>Artist \#($0 % 997)</name><anv>A\#($0 % 89)</anv></artist></artists><title>Master \#($0 * 7919 % 100_003)</title><year>\#(1950 + $0 % 70)</year><notes>\#(noise(12, seed: $0 + 20_000))</notes></master>"#
            + "\n"
    }
    var seed = 30_000
    let releases = DiscogsDumpFixture.syntheticReleases(count: 1200).split(separator: "\n").map {
        seed += 1
        return $0.replacingOccurrences(
            of: "Recorded somewhere, mastered elsewhere.", with: noise(30, seed: seed)) + "\n"
    }
    try folder.write(
        date, labels: labels.joined(), artists: artists.joined(), masters: masters.joined(),
        releases: releases.joined())
}

/// A catalog path of its own in `folder`, beside the default one.
private func otherCatalog(_ folder: borrowing DumpFolder, _ name: String) -> URL {
    folder.directory.appendingPathComponent("\(name)/discogs.sqlite", isDirectory: false)
}

/// Imports the folder's set straight through into a catalog of its own: what every resume
/// must end with.
private func straightImport(_ folder: borrowing DumpFolder) throws -> URL {
    let catalog = otherCatalog(folder, "straight")
    let summary = try runImport(from: folder.dumps, to: catalog, outsideOf: []) { _ in }
    #expect(summary.resumedBytes == 0)
    return catalog
}

/// Every row of every table in the catalog at `url`, sorted, as text, and its schema.
private func contents(of url: URL) throws -> [String: [String]] {
    let database = try Database(readOnlyAt: url)
    let schema = try database.prepare("SELECT type, name, sql FROM sqlite_master").map {
        "\(try $0.text(0)) \(try $0.text(1)) \($0.optionalText(2) ?? "")"
    }
    var contents = ["": schema.sorted()]
    let tables = try database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map { try $0.text(0) }
    for table in tables {
        let columns = try database.prepare("SELECT count(*) FROM pragma_table_info('\(table)')")
            .map { try $0.int(0) }[0]
        contents[table] = try database.prepare("SELECT * FROM \(table)").map { row in
            (0..<Int32(columns)).map { row.optionalText($0) ?? "NULL" }.joined(separator: "|")
        }.sorted()
    }
    return contents
}

/// The checkpoint the unfinished import of `catalog` holds.
private func checkpoint(of catalog: URL) throws -> ImportCheckpoint {
    try ImportCheckpoint.read(
        from: try Database(
            rollbackJournalAt: catalog.appendingPathExtension("importing"), creating: false))
}

/// Imports the folder's set into `catalog`, stopping it in `stage`: once a file's first
/// checkpoint is committed, or before the indexes. Expects the stop.
private func stopImport(
    _ folder: borrowing DumpFolder, into catalog: URL, in stage: CatalogImportProgress.Stage
) async throws {
    let dumps = folder.dumps
    let stopped = Task.detached {
        try runImport(
            from: dumps, to: catalog, outsideOf: [], checkpointBytes: smallCheckpointBytes
        ) { progress in
            let stopsHere =
                stage == .indexing
                ? progress.stage == .reading(.releases) && progress.checkpointed
                    && progress.records[.releases] == 1200
                : progress.stage == stage && progress.checkpointed
            if stopsHere { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    await #expect(throws: CatalogImportError.stopped) { try await stopped.value }
}

/// Expects the unfinished import of `catalog` to have stopped in `stage`: inside its file, or
/// with every file read.
private func expectStopped(
    _ catalog: URL, in stage: CatalogImportProgress.Stage,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let saved = try checkpoint(of: catalog)
    #expect(!saved.indexed, sourceLocation: sourceLocation)
    if case .reading(let kind) = stage {
        #expect(saved.kind == kind, sourceLocation: sourceLocation)
        #expect(saved.position != nil, sourceLocation: sourceLocation)
    } else {
        #expect(saved.filesFinished == DumpKind.allCases.count, sourceLocation: sourceLocation)
    }
    let unfinished = try #require(unfinishedImport(of: catalog), sourceLocation: sourceLocation)
    #expect(unfinished.dumpDate == date, sourceLocation: sourceLocation)
    #expect(unfinished.fraction > 0 && unfinished.fraction <= 1, sourceLocation: sourceLocation)
}

/// Carries on the unfinished import of `catalog` and expects the catalog an import straight
/// through makes, with nothing left beside it.
private func expectResumed(
    _ folder: borrowing DumpFolder, into catalog: URL, like straight: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    var reports: [CatalogImportProgress] = []
    let summary = try runImport(from: folder.dumps, to: catalog, outsideOf: []) {
        reports.append($0)
    }
    #expect(summary.resumedBytes > 0, sourceLocation: sourceLocation)
    #expect((reports.first?.bytesRead ?? 0) > 0, sourceLocation: sourceLocation)
    #expect(summary.records[.releases] == 1200, sourceLocation: sourceLocation)
    #expect(try contents(of: catalog) == contents(of: straight), sourceLocation: sourceLocation)
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: catalog.deletingLastPathComponent().path) == [catalog.lastPathComponent],
        sourceLocation: sourceLocation)
}

@Test(arguments: stages)
func aStopInEachStageResumesToTheCatalogOfAnImportStraightThrough(
    _ stage: CatalogImportProgress.Stage
) async throws {
    let folder = try DumpFolder()
    try writeSet(folder)
    let straight = try straightImport(folder)
    try await stopImport(folder, into: folder.catalog, in: stage)
    try expectStopped(folder.catalog, in: stage)
    try expectResumed(folder, into: folder.catalog, like: straight)
}

/// The DiscogsImport tool the build put beside this test bundle, found from the bundle's own
/// binary, as the test runner loads it.
private func importTool() throws -> URL {
    var image = Dl_info()
    try #require(dladdr(#dsohandle, &image) != 0, "this test's image has no path")
    var folder = URL(fileURLWithPath: String(cString: image.dli_fname), isDirectory: false)
    while folder.path != "/" {
        folder.deleteLastPathComponent()
        let tool = folder.appendingPathComponent("DiscogsImport", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: tool.path) { return tool }
    }
    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "DiscogsImport"])
}

@Test(arguments: stages)
func aCrashInEachStageResumesToTheCatalogOfAnImportStraightThrough(
    _ stage: CatalogImportProgress.Stage
) throws {
    let folder = try DumpFolder()
    try writeSet(folder)
    let straight = try straightImport(folder)
    let name =
        switch stage {
        case .reading(let kind): kind.rawValue
        default: "indexing"
        }
    let process = Process()
    process.executableURL = try importTool()
    process.arguments = [
        folder.dumps.path, "--catalog", folder.catalog.path, "--checkpoint-bytes",
        "\(smallCheckpointBytes)", "--crash-at", name,
    ]
    // A home of its own, so the tool reads no config file and finds no watched folders.
    let home = folder.directory.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    process.environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path]
    let errors = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(message.isEmpty)
    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGKILL)
    let saved = try checkpoint(of: folder.catalog)
    #expect(!saved.indexed)
    if case .reading(let kind) = stage {
        // Killed at the first report after a checkpoint in the file: inside it, or at its end.
        let index = try #require(DumpKind.allCases.firstIndex(of: kind))
        #expect(saved.filesFinished == index || saved.filesFinished == index + 1)
    } else {
        #expect(saved.filesFinished == DumpKind.allCases.count)
    }
    try expectResumed(folder, into: folder.catalog, like: straight)
}

@Test func rowsWrittenAfterTheLastCheckpointAreRolledBackBeforeAResume() async throws {
    let folder = try DumpFolder()
    try writeSet(folder)
    let straight = try straightImport(folder)
    try await stopImport(folder, into: folder.catalog, in: .reading(.releases))
    // Rows past the checkpoint, spilled to the file before a commit that never comes, as a
    // killed import leaves them: the file and its journal are copied as they are on disk.
    let building = folder.catalog.appendingPathExtension("importing")
    let copy = otherCatalog(folder, "killed")
    try FileManager.default.createDirectory(
        at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try Database(rollbackJournalAt: building, creating: false)
    try writer.execute("PRAGMA cache_size = 2; BEGIN")
    let insert = try writer.prepare(
        "INSERT INTO title_keys (artist_key, title_key, release_id) VALUES (?, ?, ?)")
    for id in 0..<5000 { try insert.run("killed\(id)", "after the checkpoint", id) }
    for suffix in ["", "-journal"] {
        try FileManager.default.copyItem(
            atPath: building.path + suffix,
            toPath: copy.appendingPathExtension("importing").path + suffix)
    }
    try writer.execute("ROLLBACK")
    try expectResumed(folder, into: copy, like: straight)
}

@Test func anUnfinishedImportOfAnotherDumpIsReplaced() async throws {
    let folder = try DumpFolder()
    try writeSet(folder, date: "20261001")
    try await stopImport(folder, into: folder.catalog, in: .reading(.masters))
    try writeSet(folder)
    let summary = try runImport(from: folder.dumps, to: folder.catalog, outsideOf: []) { _ in }
    #expect(summary.resumedBytes == 0)
    #expect(summary.dumpDate == date)
    #expect(try Catalog(at: folder.catalog).dumpDate == date)
    #expect(try folder.leftovers == [])
}

@Test func aDamagedCheckpointStartsTheImportOver() async throws {
    let folder = try DumpFolder()
    try writeSet(folder)
    let straight = try straightImport(folder)
    let building = folder.catalog.appendingPathExtension("importing")
    for damage in [
        "UPDATE import_checkpoint SET checkpoint = replace(checkpoint, '\"bits\":', '\"bits\": ')",
        "DELETE FROM import_checkpoint", "DROP TABLE import_checkpoint",
    ] {
        try await stopImport(folder, into: folder.catalog, in: .reading(.artists))
        try Database(rollbackJournalAt: building, creating: false).execute(damage)
        #expect(unfinishedImport(of: folder.catalog) == nil)
        let summary = try runImport(from: folder.dumps, to: folder.catalog, outsideOf: []) { _ in }
        #expect(summary.resumedBytes == 0)
        #expect(try contents(of: folder.catalog) == contents(of: straight))
    }
    // A checkpoint that matches its hash but whose record is before its access point.
    try await stopImport(folder, into: folder.catalog, in: .reading(.artists))
    var inconsistent = try checkpoint(of: folder.catalog)
    inconsistent.position?.record.offset = -1
    let database = try Database(rollbackJournalAt: building, creating: false)
    try database.transaction { try inconsistent.write(to: database) }
    #expect(unfinishedImport(of: folder.catalog) == nil)
    #expect(try folder.importCatalog().resumedBytes == 0)
    #expect(try contents(of: folder.catalog) == contents(of: straight))
    // Not a database at all.
    try Data("not SQLite".utf8).write(to: building)
    #expect(unfinishedImport(of: folder.catalog) == nil)
    #expect(try folder.importCatalog().resumedBytes == 0)
    #expect(try contents(of: folder.catalog) == contents(of: straight))
}

@Test func startingOverIgnoresTheUnfinishedImport() async throws {
    let folder = try DumpFolder()
    try writeSet(folder)
    try await stopImport(folder, into: folder.catalog, in: .reading(.releases))
    let summary = try runImport(
        from: folder.dumps, to: folder.catalog, outsideOf: [], startingOver: true
    ) { _ in }
    #expect(summary.resumedBytes == 0)
    #expect(try folder.leftovers == [])
}

@Test func aCompleteCatalogLeftBeforeItsSwapIsSwappedIn() throws {
    let folder = try DumpFolder()
    try writeSet(folder)
    let straight = try straightImport(folder)
    try FileManager.default.createDirectory(
        at: folder.catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: straight, to: folder.catalog.appendingPathExtension("importing"))
    var stages: [CatalogImportProgress.Stage] = []
    let summary = try folder.importCatalog { stages.append($0.stage) }
    #expect(stages == [.finished])
    #expect(summary.resumedBytes == summary.compressedBytes)
    #expect(summary.records[.releases] == 1200)
    #expect(try contents(of: folder.catalog) == contents(of: straight))
}

@Test func dumpsThatCantBeReadKeepTheUnfinishedImport() throws {
    let folder = try DumpFolder()
    try writeSet(folder)
    let straight = try straightImport(folder)
    let releases = folder.file(date, .releases)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: releases.path)
    #expect(throws: CatalogImportError.self) { try folder.importCatalog() }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: releases.path)
    #expect(try checkpoint(of: folder.catalog).kind == .releases)
    try expectResumed(folder, into: folder.catalog, like: straight)
}
