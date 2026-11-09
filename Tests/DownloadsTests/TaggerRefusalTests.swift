import Foundation
import SQLite
import Testing

@testable import Discogs
@testable import Downloads
@testable import Recommender

// Open in Tagger says why a job can't open, rather than doing nothing.

/// A catalog with no releases in a temporary folder, as an import of an empty dump leaves it.
private func emptyCatalog() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "catalog-\(UUID().uuidString).sqlite", isDirectory: false)
    let database = try Database(at: url)
    try database.execute(CatalogSchema.tables)
    try database.prepare("INSERT INTO catalog (dump_date, schema) VALUES (?, ?)")
        .run("20261101", CatalogSchema.identity)
    return url
}

@Test func aJobTheTaggerCantOpenSaysWhy() async throws {
    let catalog = try emptyCatalog()
    let staged = job(1) { $0.tagging.status = .discrepancy }
    #expect(
        await Downloads.taggerRefusal(staged, catalog: catalog)
            == "release 4242 is not in the local catalog")
    #expect(
        await Downloads.taggerRefusal(staged, catalog: nil)
            == "this Mac has no Discogs catalog to tag with")
    let unstaged = job(1) { $0.stagedPath = nil }
    #expect(
        await Downloads.taggerRefusal(unstaged, catalog: catalog)
            == "music-recommender hasn't said where it staged the files")
    let outside = job(1) { $0.stagedPath = "../library" }
    #expect(
        await Downloads.taggerRefusal(outside, catalog: catalog)
            == DownloadJob.notOneFolder("../library"))
    let noFormat = job(1) { $0.candidate = nil }
    #expect(
        await Downloads.taggerRefusal(noFormat, catalog: catalog)
            == "music-recommender hasn't said what format it downloaded")
    let unreadable = catalog.deletingLastPathComponent().appendingPathComponent("none.sqlite")
    #expect(
        await Downloads.taggerRefusal(staged, catalog: unreadable)?
            .hasPrefix("the Discogs catalog couldn't be read") == true)
}
