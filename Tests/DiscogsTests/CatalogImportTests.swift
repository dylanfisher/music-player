import Foundation
import SQLite
import Testing

@testable import Discogs
@testable import Fixtures
@testable import Library
@testable import Settings

private let oldDate = "20261001"
private let newDate = "20261101"
private let oldRelease = #"<release id="1"><title>Old</title></release>"# + "\n"
private let newRelease = #"<release id="1"><title>New</title></release>"# + "\n"

/// A folder whose catalog was imported from an older set, with a newer set beside it.
private func folderWithOldCatalog() throws -> DumpFolder {
    let folder = try DumpFolder()
    try folder.write(oldDate, releases: oldRelease)
    try folder.importCatalog()
    try folder.write(newDate, releases: newRelease)
    return folder
}

/// Imports the folder's newest set and expects `error`, then expects the old catalog still in
/// use and nothing of the new one left.
private func expectFailure(
    _ folder: borrowing DumpFolder, _ error: CatalogImportError,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(throws: error, sourceLocation: sourceLocation) { try folder.importCatalog() }
    let catalog = try Catalog(at: folder.catalog)
    #expect(catalog.dumpDate == oldDate, sourceLocation: sourceLocation)
    #expect(try catalog.release(id: 1)?.title == "Old", sourceLocation: sourceLocation)
    #expect(try folder.leftovers == [], sourceLocation: sourceLocation)
}

@Test func aNewImportReplacesTheCatalogAndReportsItsProgress() throws {
    let folder = try folderWithOldCatalog()
    let old = try Catalog(at: folder.catalog)
    var reports: [CatalogImportProgress] = []
    let summary = try folder.importCatalog { reports.append($0) }
    #expect(summary.dumpDate == newDate)
    #expect(summary.records == [.labels: 0, .artists: 0, .masters: 0, .releases: 1])
    #expect(summary.catalogBytes > 0)
    #expect(try Catalog(at: folder.catalog).release(id: 1)?.title == "New")
    // A connection opened before the swap reads the catalog it opened, or the system SQLite
    // fails it with an I/O error; it never reads the new one. The window opens the new one
    // once an import ends.
    if case .success(let title) = Result(catching: { try old.release(id: 1)?.title }) {
        #expect(title == "Old")
    }
    #expect(try folder.leftovers == [])
    // Each stage in order, with the counts between.
    let stages = reports.map(\.stage).reduce(into: [CatalogImportProgress.Stage]()) {
        if $0.last != $1 { $0.append($1) }
    }
    #expect(stages == DumpKind.allCases.map { .reading($0) } + [.indexing, .finished])
    #expect(reports.last?.fraction == 1)
    #expect(reports.last?.bytesRead == summary.compressedBytes)
    #expect(
        reports.last?.text
            == "Imported the 20261101 dump: 0 labels, 0 artists, 0 masters, 1 releases")
}

@Test func aTruncatedFileFailsAndTheOldCatalogStays() throws {
    let folder = try folderWithOldCatalog()
    try folder.write(newDate, releases: DiscogsDumpFixture.syntheticReleases(count: 200))
    let file = folder.file(newDate, .releases)
    let data = try Data(contentsOf: file)
    try data.prefix(data.count / 2).write(to: file)
    try DiscogsDumpFixture.writeChecksums(date: newDate, in: folder.dumps)
    try expectFailure(folder, .truncated(file.lastPathComponent))
}

@Test func aFileThatDoesntMatchItsChecksumFailsAndTheOldCatalogStays() throws {
    let folder = try folderWithOldCatalog()
    let checksums = folder.dumps.appendingPathComponent(
        DiscogsDumpFixture.checksumFileName(date: newDate))
    let name = folder.file(newDate, .masters).lastPathComponent
    let listed = try DumpSet.checksums(in: checksums)
    let wrong = String(repeating: "0", count: 64)
    try (listed.map { "\($0.key == name ? wrong : $0.value) \($0.key)" }.joined(separator: "\n"))
        .write(to: checksums, atomically: true, encoding: .utf8)
    let actual = try #require(listed[name])
    try expectFailure(folder, .checksumMismatch(name, expected: wrong, actual: actual))
}

@Test func dataThatIsntGzipOrADumpFailsAndTheOldCatalogStays() throws {
    let folder = try folderWithOldCatalog()
    let file = folder.file(newDate, .artists)
    try Data("not gzip".utf8).write(to: file)
    try DiscogsDumpFixture.writeChecksums(date: newDate, in: folder.dumps)
    try expectFailure(folder, .corrupt(file.lastPathComponent, "incorrect header check"))

    for (xml, line, reason) in [
        (
            "<artists>\n<artist><name>No ID</name></artist>\n</artists>\n", 2,
            "a <artist> with no id"
        ),
        (
            "<artists>\n<artist><id>1</id></artist>\n<artist><id>2</id>", 3,
            "the file ends inside a record"
        ),
        ("<releases>\n</releases>\n", 1, "no <artists>"),
    ] {
        try DiscogsDumpFixture.writeGzip(Data(xml.utf8), to: file)
        try DiscogsDumpFixture.writeChecksums(date: newDate, in: folder.dumps)
        try expectFailure(folder, .malformed(file.lastPathComponent, line: line, reason))
    }
}

@Test func aStoppedImportLeavesTheOldCatalogInUse() async throws {
    let folder = try folderWithOldCatalog()
    try folder.write(newDate, releases: DiscogsDumpFixture.syntheticReleases(count: 2000))
    let dumps = folder.dumps
    let catalog = folder.catalog
    let stopped = Task.detached {
        try runImport(from: dumps, to: catalog, outsideOf: []) { progress in
            // Stops the import's own task once the releases are under way.
            if progress.stage == .reading(.releases), (progress.records[.releases] ?? 0) > 0 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
    await #expect(throws: CatalogImportError.stopped) { try await stopped.value }
    #expect(try Catalog(at: folder.catalog).dumpDate == oldDate)
    // The unfinished catalog stays, for the next import to carry on.
    #expect(try folder.leftovers == [folder.catalog.lastPathComponent + ".importing"])
}

@Test func theNewestCompleteSetIsImported() throws {
    let folder = try DumpFolder()
    #expect(throws: CatalogImportError.self) { try folder.importCatalog() }
    try folder.write(oldDate, releases: oldRelease)
    try folder.write(newDate, releases: newRelease)
    // A newer set still downloading, and one whose checksum file doesn't list every file.
    try FileManager.default.removeItem(at: folder.file(newDate, .releases))
    try folder.write("20261201", releases: newRelease)
    let checksums = folder.dumps.appendingPathComponent(
        DiscogsDumpFixture.checksumFileName(date: "20261201"))
    let lines = try String(contentsOf: checksums, encoding: .utf8).split(separator: "\n")
    try lines.dropLast().joined(separator: "\n").write(
        to: checksums, atomically: true, encoding: .utf8)
    #expect(try folder.importCatalog().dumpDate == oldDate)
}

@Test func aCatalogInsideAWatchedFolderIsRefused() throws {
    let folder = try DumpFolder()
    try folder.write(newDate, releases: newRelease)
    let watched = folder.directory.appendingPathComponent("data/../data").path
    #expect(
        throws: CatalogImportError.catalogInsideWatchedFolder(
            catalog: folder.catalog.path, folder: watched)
    ) { try folder.importCatalog(outsideOf: [watched]) }
    #expect(
        !FileManager.default.fileExists(atPath: folder.catalog.deletingLastPathComponent().path))
    try folder.importCatalog(outsideOf: [folder.dumps.path])
}

@Test func aCatalogBuiltWithOtherTablesIsntRead() throws {
    let folder = try DumpFolder()
    #expect(throws: CatalogError.missing(folder.catalog.path)) { try Catalog(at: folder.catalog) }
    try folder.write(newDate, releases: newRelease)
    try folder.importCatalog()
    let database = try Database(at: folder.catalog)
    try database.execute("UPDATE catalog SET schema = 'CREATE TABLE releases (id)'")
    #expect(throws: CatalogError.builtByAnotherVersion(folder.catalog.path)) {
        try Catalog(at: folder.catalog)
    }
}

@Test func theDumpsFolderIsFoundWhereItsShareIsMounted() throws {
    let shares = [MountedShare(url: "smb://nas.local/music", mountPoint: "/Volumes/music-1")]
    #expect(
        try locate(DumpsFolder(path: "discogs", share: "smb://nas/music"), among: shares).path
            == "/Volumes/music-1/discogs")
    #expect(try locate(DumpsFolder(path: "/Users/me/dumps"), among: []).path == "/Users/me/dumps")
    #expect(throws: CatalogImportError.shareNotMounted("smb://nas/other")) {
        try locate(DumpsFolder(path: "discogs", share: "smb://nas/other"), among: shares)
    }
}

@Test func aCatalogThatCantBeWrittenFailsSayingSo() throws {
    let folder = try DumpFolder()
    try folder.write(newDate, releases: newRelease)
    // The catalog's folder is a file.
    let blocked = folder.directory.appendingPathComponent("file", isDirectory: false)
    try Data().write(to: blocked)
    let catalog = blocked.appendingPathComponent("discogs.sqlite", isDirectory: false)
    #expect {
        try runImport(from: folder.dumps, to: catalog, outsideOf: []) { _ in }
    } throws: { error in
        guard case .unwritable(let path, _) = error as? CatalogImportError else { return false }
        return path == catalog.appendingPathExtension("importing").path
    }
}

@Test func aCatalogsStatusIsItsDumpDateItsImportItsSizeAndItsPlace() throws {
    let folder = try DumpFolder()
    #expect(throws: CatalogError.missing(folder.catalog.path)) {
        try CatalogStatus(at: folder.catalog)
    }
    try folder.write(newDate, releases: newRelease)
    let started = Date()
    let summary = try folder.importCatalog()
    let status = try CatalogStatus(at: folder.catalog)
    #expect(status.dumpDate == newDate)
    #expect(status.sizeBytes == summary.catalogBytes)
    #expect(status.url == folder.catalog)
    // File times are kept to the second on some file systems.
    #expect(status.importedAt >= started.addingTimeInterval(-1))
    #expect(status.importedAt <= Date())
    _ = try Catalog(at: folder.catalog).release(id: 1)
    #expect(
        try CatalogStatus(at: folder.catalog).importedAt == status.importedAt, "reads don't move it"
    )
}
