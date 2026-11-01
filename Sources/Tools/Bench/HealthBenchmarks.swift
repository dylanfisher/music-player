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
            (0..<10).map { _ in { reports.append(try index.healthReport()) } })
        guard let report = reports.last else { throw BenchError.expected("a report") }
        // Not budgeted: the sidebar's folder tree, read once per library refresh.
        var tree = FolderTree()
        let treeSamples = try millisecondSamples(
            (0..<10).map { _ in { tree = try index.folderTree(roots: [library.folder.path]) } })
        let found = HealthCheck.allCases.map { "\($0.rawValue) \(report[$0].count)" }
        return Measured(
            value: p95(samples) / 1000,
            notes: [
                slowestNote(samples), "found: " + found.joined(separator: ", "),
                "folder tree p95 \(String(format: "%.2f", p95(treeSamples))) ms,"
                    + " \(tree.subfolders(of: library.folder.path).count) top-level folders",
            ])
    }
]
