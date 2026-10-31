import Fixtures
import Foundation

let fixtureBenchmarks = [
    Benchmark(
        name: "fixtures: generate \(fullLibraryFileCount) files",
        budget: Budget(appleSilicon: 30, oldMac: 120, unit: .seconds)
    ) {
        try withScratchDirectory("fixtures") { root in
            try seconds { _ = try generateFixtures(count: fullLibraryFileCount, in: root) }
        }
    },
    Benchmark(
        name: "fixtures: rerun with nothing to do",
        budget: Budget(appleSilicon: 10, oldMac: 30, unit: .seconds)
    ) {
        try withScratchDirectory("fixtures") { root in
            _ = try generateFixtures(count: fullLibraryFileCount, in: root)
            var outcome = FixtureGeneration.generated
            let elapsed = try seconds {
                outcome = try generateFixtures(count: fullLibraryFileCount, in: root)
            }
            guard outcome == .upToDate else {
                throw BenchError.expected("the rerun to skip writing")
            }
            return elapsed
        }
    },
]
