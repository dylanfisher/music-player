import Foundation

/// The machines the budgets in docs/plan.md are set for.
enum MachineClass: String, CaseIterable, Sendable {
    case appleSilicon = "Apple Silicon"
    /// The 2015 MacBook Pro on macOS 12. Every Intel Mac is held to its budget.
    case oldMac = "old Mac"

    static var current: MachineClass {
        #if arch(arm64)
            .appleSilicon
        #else
            .oldMac
        #endif
    }
}

/// The most a benchmark may measure on each machine class. docs/plan.md has the human copy.
struct Budget: Sendable {
    enum Unit: String, Sendable {
        case milliseconds = "ms"
        case seconds = "s"
        case megabytes = "MB"
    }

    var appleSilicon: Double
    var oldMac: Double
    var unit: Unit

    func limit(on machine: MachineClass) -> Double {
        switch machine {
        case .appleSilicon: appleSilicon
        case .oldMac: oldMac
        }
    }
}

/// One named measurement and its budget.
struct Benchmark: Sendable {
    var name: String
    var budget: Budget
    var measure: @Sendable () throws -> Measured
}

/// What a benchmark measured, in its budget's unit, and any other numbers worth printing under
/// its row.
struct Measured {
    var value: Double
    var notes: [String] = []
}

enum BenchError: Error, CustomStringConvertible {
    case expected(String)

    var description: String {
        switch self {
        case .expected(let what): "expected \(what)"
        }
    }
}

struct BenchmarkResult {
    enum Outcome {
        case withinBudget(Double)
        case overBudget(Double)
        case failed(any Error)
    }

    var name: String
    var limit: Double
    var unit: Budget.Unit
    var outcome: Outcome
    var notes: [String] = []

    var passed: Bool {
        if case .withinBudget = outcome { return true }
        return false
    }
}

/// Runs each benchmark in turn. A thrown error is reported as a failure and doesn't stop the
/// rest. `progress` gets each name before it runs, since some take tens of seconds.
func run(
    _ benchmarks: [Benchmark], on machine: MachineClass, progress: (String) -> Void = { _ in }
) -> [BenchmarkResult] {
    benchmarks.map { benchmark in
        progress(benchmark.name)
        let limit = benchmark.budget.limit(on: machine)
        let outcome: BenchmarkResult.Outcome
        var notes: [String] = []
        do {
            let measured = try benchmark.measure()
            notes = measured.notes
            outcome =
                measured.value < limit
                ? .withinBudget(measured.value) : .overBudget(measured.value)
        } catch {
            outcome = .failed(error)
        }
        return BenchmarkResult(
            name: benchmark.name, limit: limit, unit: benchmark.budget.unit, outcome: outcome,
            notes: notes)
    }
}

func table(_ results: [BenchmarkResult], machine: MachineClass) -> String {
    let nameWidth = max(9, results.map(\.name.count).max() ?? 0)
    func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
    }
    func amount(_ value: Double, _ unit: Budget.Unit) -> String {
        let number = value >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)
        return "\(number) \(unit.rawValue)"
    }
    var lines = [
        "Budgets for \(machine.rawValue)", "",
        pad("benchmark", nameWidth) + "  " + pad("measured", 14) + "  " + pad("budget", 16)
            + "  result",
    ]
    for result in results {
        let (measured, verdict): (String, String) =
            switch result.outcome {
            case .withinBudget(let value): (amount(value, result.unit), "ok")
            case .overBudget(let value): (amount(value, result.unit), "OVER BUDGET")
            case .failed(let error): ("-", "error: \(error)")
            }
        lines.append(
            pad(result.name, nameWidth) + "  " + pad(measured, 14) + "  "
                + pad("< " + amount(result.limit, result.unit), 16) + "  " + verdict)
        lines += result.notes.map { "    " + $0 }
    }
    return lines.joined(separator: "\n")
}

/// Milliseconds for one run of `body`: the median of `iterations` runs, after one untimed
/// warm-up run. `setUp` runs untimed before each.
func medianMilliseconds(
    iterations: Int, setUp: () throws -> Void = {}, _ body: () throws -> Void
) throws -> Double {
    try setUp()
    try body()
    var samples: [Double] = []
    for _ in 0..<iterations {
        try setUp()
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    return samples.sorted()[samples.count / 2]
}

/// Milliseconds for each run of each body, in order, for benchmarks that report a percentile
/// over many different inputs.
func millisecondSamples(_ bodies: [() throws -> Void]) throws -> [Double] {
    try bodies.map { body in
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
}

/// The value 95% of `samples` are at or below.
func p95(_ samples: [Double]) -> Double {
    precondition(!samples.isEmpty, "no samples")
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
}

/// Seconds for a single run of `body`, for benchmarks too slow to repeat.
func seconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

/// Runs `body` with a fresh directory for its files, then deletes the directory.
func withScratchDirectory<T>(_ name: String, _ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bench-\(name)-\(UUID().uuidString)")
    let result = Result { try body(url) }
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    return try result.get()
}
