import Discogs
import Fixtures
import Foundation

/// The releases in the import rows' fixture dump: about a thousandth of the 2026-11-01 dump.
private let fixtureReleases = 20_000

/// One import of the fixture dump into a new catalog, with the footprint it added at its peak.
private struct FixtureImport {
    var summary: CatalogImportSummary
    var footprintBeforeMB: Double
    var footprintPeakMB: Double
}

private let fixtureImport = Result { () throws -> FixtureImport in
    try withScratchDirectory("discogs-import") { directory in
        let dumps = directory.appendingPathComponent("dumps", isDirectory: true)
        try DiscogsDumpFixture.writeSet(
            date: "20261101",
            releases: DiscogsDumpFixture.syntheticReleases(count: fixtureReleases), in: dumps)
        let catalog = directory.appendingPathComponent("catalog.sqlite", isDirectory: false)
        let before = try footprintMB()
        let peak = PeakFootprint()
        let summary = try waited {
            try await importCatalog(from: dumps, to: catalog, outsideOf: []) { _ in }
        }
        guard summary.records[.releases] == fixtureReleases else {
            throw BenchError.expected("\(fixtureReleases) releases imported: \(summary.records)")
        }
        return FixtureImport(
            summary: summary, footprintBeforeMB: before, footprintPeakMB: try peak.stop())
    }
}

let discogsBenchmarks = [
    Benchmark(
        name: "discogs: import a \(fixtureReleases)-release fixture dump",
        budget: Budget(appleSilicon: 5, oldMac: 20, unit: .seconds)
    ) {
        let run = try fixtureImport.get()
        return Measured(
            value: run.summary.seconds,
            notes: [
                String(
                    format: "%.0f releases a second, %.1f MB gzip, %.0f MB added at the peak",
                    Double(fixtureReleases) / run.summary.seconds,
                    Double(run.summary.compressedBytes) / 1e6,
                    run.footprintPeakMB - run.footprintBeforeMB)
            ])
    },
    Benchmark(
        name: "discogs: the catalog of that fixture dump",
        budget: Budget(appleSilicon: 60, oldMac: 60, unit: .megabytes)
    ) {
        Measured(value: Double(try fixtureImport.get().summary.catalogBytes) / 1e6)
    },
]
