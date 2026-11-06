import Analysis
import Fixtures
import Foundation

/// The file the analysis rows time: five minutes of full-band 24/96 noise, which FLAC can't
/// shrink much, so it reads as much as any 24/96 recording of that length.
private let benchSeconds = 300

/// One analysis of the bench file locally, with the footprint it added at its peak.
private struct LocalAnalysis {
    var seconds: Double
    var footprintBeforeMB: Double
    var footprintPeakMB: Double
    var fileMB: Double
}

private let benchFile = Result {
    try analysisFixture(.hiRes, seconds: benchSeconds, in: try defaultPlaybackFixturesDirectory())
}

private let localAnalysis = Result { () throws -> LocalAnalysis in
    let url = try benchFile.get()
    // A first run, so the file is in the page cache, as a second look at a local file is.
    _ = try analyzeFile(at: url)
    let before = try footprintMB()
    let peak = PeakFootprint()
    let elapsed = try seconds { _ = try analyzeFile(at: url) }
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    return LocalAnalysis(
        seconds: elapsed, footprintBeforeMB: before, footprintPeakMB: try peak.stop(),
        fileMB: Double(size) / 1e6)
}

let analysisBenchmarks = [
    Benchmark(
        name: "analysis: a 5-minute 24/96 FLAC, local",
        budget: Budget(appleSilicon: 2, oldMac: 12, unit: .seconds)
    ) {
        let analysis = try localAnalysis.get()
        return Measured(
            value: analysis.seconds,
            notes: [
                String(
                    format: "%.0f MB, %.0fx real time, from the page cache", analysis.fileMB,
                    Double(benchSeconds) / analysis.seconds)
            ])
    },
    Benchmark(
        name: "analysis: the same on the slow simulated NAS",
        budget: Budget(appleSilicon: 6, oldMac: 20, unit: .seconds)
    ) {
        let url = try benchFile.get()
        let elapsed = try seconds { _ = try analyzeFile(at: url, latency: nasFileLatency) }
        return Measured(
            value: elapsed,
            notes: [
                String(
                    format: "%.0f ms to open, %.0f ms a 1 MB block, as the play rows wait",
                    nasFileLatency.openSeconds * 1000, nasFileLatency.readSeconds * 1000)
            ])
    },
    // Measured as growth, since earlier benchmarks in the same process leave their own memory.
    Benchmark(
        name: "analysis: memory it adds at its peak",
        budget: Budget(appleSilicon: 10, oldMac: 10, unit: .megabytes)
    ) {
        let analysis = try localAnalysis.get()
        return Measured(
            value: analysis.footprintPeakMB - analysis.footprintBeforeMB,
            notes: [
                String(
                    format: "footprint %.0f MB before, %.0f MB at the peak",
                    analysis.footprintBeforeMB, analysis.footprintPeakMB)
            ])
    },
]
