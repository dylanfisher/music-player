import Analysis
import Foundation
import Library
import Settings

let healthBenchmarks = [
    Benchmark(
        name: "library: build the health report over every fixture track (p95)",
        budget: Budget(appleSilicon: 1, oldMac: 3, unit: .seconds)
    ) {
        let library = try scannedLibrary.get()
        let index = library.index
        var reports: [HealthReport] = []
        let samples = try millisecondSamples(
            (0..<10).map { _ in
                { reports.append(try index.healthReport(measuredChecks: healthChecks)) }
            })
        guard let report = reports.last else { throw BenchError.expected("a report") }
        let found = HealthCheck.allCases.map { "\($0.rawValue) \(report[$0].count)" }
        return Measured(
            value: p95(samples) / 1000,
            notes: [slowestNote(samples), "found: " + found.joined(separator: ", ")])
    }
]
