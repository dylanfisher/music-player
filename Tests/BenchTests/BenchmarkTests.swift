import Testing

@testable import Bench

private struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}

private let budget = Budget(appleSilicon: 10, oldMac: 40, unit: .milliseconds)

@Test func eachMachineClassHasItsOwnLimit() {
    #expect(budget.limit(on: .appleSilicon) == 10)
    #expect(budget.limit(on: .oldMac) == 40)
}

@Test func reportsMissesAndErrorsWithoutStopping() {
    let results = run(
        [
            Benchmark(name: "fast", budget: budget) { 3 },
            Benchmark(name: "slow", budget: budget) { 25 },
            Benchmark(name: "broken", budget: budget) { throw Boom() },
        ], on: .appleSilicon)
    #expect(results.map(\.passed) == [true, false, false])
    #expect(run([Benchmark(name: "slow", budget: budget) { 25 }], on: .oldMac)[0].passed)

    let report = table(results, machine: .appleSilicon)
    #expect(report.contains("Apple Silicon"))
    #expect(report.contains("OVER BUDGET"))
    #expect(report.contains("error: boom"))
    #expect(report.contains("< 10.00 ms"))
}

@Test func benchmarkNamesAreUnique() {
    let names = benchmarks.map(\.name)
    #expect(Set(names).count == names.count)
}
