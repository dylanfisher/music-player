import Foundation

@testable import Discogs
@testable import Fixtures

/// A folder of its own for one test's dumps and catalogs, removed when it's done.
struct DumpFolder: ~Copyable {
    let directory: URL
    var dumps: URL { directory.appendingPathComponent("dumps", isDirectory: true) }
    var catalog: URL { directory.appendingPathComponent("data/discogs.sqlite", isDirectory: false) }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("discogs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            preconditionFailure("couldn't remove \(directory.path): \(error)")
        }
    }

    /// Writes a set of `date` with these records, each kind inside its root element.
    func write(
        _ date: String, labels: String = "", artists: String = "", masters: String = "",
        releases: String
    ) throws {
        try DiscogsDumpFixture.writeSet(
            date: date, labels: labels, artists: artists, masters: masters, releases: releases,
            in: dumps)
    }

    /// The file of one dump in the folder.
    func file(_ date: String, _ kind: DumpKind) -> URL {
        dumps.appendingPathComponent(DiscogsDumpFixture.fileName(date: date, kind: kind.rawValue))
    }

    /// Imports the folder's newest set into the catalog, on this thread.
    @discardableResult
    func importCatalog(
        outsideOf watched: [String] = [], progress: (CatalogImportProgress) -> Void = { _ in }
    ) throws(CatalogImportError) -> CatalogImportSummary {
        try runImport(from: dumps, to: catalog, outsideOf: watched, progress: progress)
    }

    /// Imports the set, then opens the catalog.
    func importedCatalog() throws -> Catalog {
        try importCatalog()
        return try Catalog(at: catalog)
    }

    /// Whether anything but the catalog is left beside it, such as an unfinished import.
    var leftovers: [String] {
        get throws {
            try FileManager.default.contentsOfDirectory(
                atPath: catalog.deletingLastPathComponent().path
            ).filter { $0 != catalog.lastPathComponent }
        }
    }
}
