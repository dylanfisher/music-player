import Foundation
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
            Benchmark(name: "fast", budget: budget) { Measured(value: 3, notes: ["3 of 10"]) },
            Benchmark(name: "slow", budget: budget) { Measured(value: 25) },
            Benchmark(name: "broken", budget: budget) { throw Boom() },
        ], on: .appleSilicon)
    #expect(results.map(\.passed) == [true, false, false])
    #expect(
        run([Benchmark(name: "slow", budget: budget) { Measured(value: 25) }], on: .oldMac)[0]
            .passed)

    let report = table(results, machine: .appleSilicon)
    #expect(report.contains("Apple Silicon"))
    #expect(report.contains("OVER BUDGET"))
    #expect(report.contains("error: boom"))
    #expect(report.contains("< 10.00 ms"))
    #expect(report.contains("\n    3 of 10\n"))
}

@Test func aZeroBudgetAllowsOnlyZero() {
    let zero = Budget(appleSilicon: 0, oldMac: 0, unit: .frames)
    #expect(zero.allows(0, on: .appleSilicon))
    #expect(!zero.allows(1, on: .appleSilicon))
    #expect(
        table(
            run([Benchmark(name: "z", budget: zero) { Measured(value: 0) }], on: .oldMac),
            machine: .oldMac
        ).contains("0 frames"))
}

@Test func benchmarkNamesAreUnique() {
    let names = benchmarks.map(\.name)
    #expect(Set(names).count == names.count)
}

/// "| a | b |" -> ["a", "b"].
private func cells(_ row: Substring) -> [String] {
    row.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

/// docs/plan.md holds the human copy of every budget; the code holds the one that is enforced.
@Test func everyBudgetMatchesTheTableInThePlan() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let plan = try String(contentsOf: root.appendingPathComponent("docs/plan.md"), encoding: .utf8)
    let lines = plan.split(separator: "\n", omittingEmptySubsequences: false)
    let header = try #require(
        lines.firstIndex { $0.hasPrefix("| What |") }, "no budget table in docs/plan.md")
    let titles = cells(lines[header]).map { $0.lowercased() }
    let rows = lines[(header + 2)...].prefix { $0.hasPrefix("|") }.map(cells)

    func text(_ value: Double, _ unit: Budget.Unit) -> String {
        if value == 0 { return "0 " + unit.rawValue }
        return "< " + (value == value.rounded() ? String(Int(value)) : "\(value)") + " "
            + unit.rawValue
    }
    for benchmark in benchmarks {
        let limits = try MachineClass.allCases.map { machine in
            (
                column: try #require(
                    titles.firstIndex(of: machine.rawValue.lowercased()),
                    "no \(machine.rawValue) column in the budget table"),
                text: text(benchmark.budget.limit(on: machine), benchmark.budget.unit)
            )
        }
        #expect(
            rows.contains { row in limits.allSatisfy { row[$0.column] == $0.text } },
            "no row in the plan's budget table for \"\(benchmark.name)\": \(limits.map(\.text))")
    }
}
