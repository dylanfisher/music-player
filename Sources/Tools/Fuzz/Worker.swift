import Foundation
import FuzzCoverage

/// How long one input may run before it counts as a hang.
let inputTimeoutSeconds: UInt32 = 10

/// A target's folders under the run's output folder.
struct FuzzFolders {
    let output: URL
    var seeds: URL { output.appendingPathComponent("seeds") }
    /// Inputs that found new coverage, kept across runs.
    var corpus: URL { output.appendingPathComponent("corpus") }
    var crashes: URL { output.appendingPathComponent("crashes") }
    /// Where the crash handler writes the input that crashed a worker.
    var pending: URL { output.appendingPathComponent("crash-pending") }
    var candidate: URL { output.appendingPathComponent("minimise-candidate") }
}

/// Runs one input with coverage cleared before it, under the hang timer, with the crash handler
/// holding it. Returns whether the target accepted it and how many new features it hit.
@MainActor func execute(_ input: [UInt8], _ run: ([UInt8]) -> Bool) -> (
    accepted: Bool, features: Int
) {
    input.withUnsafeBufferPointer { buffer in
        FuzzCoverageClear()
        FuzzCoverageBeginInput(buffer.baseAddress, buffer.count)
        FuzzCoverageSetTimeout(inputTimeoutSeconds)
        let accepted = run(input)
        FuzzCoverageSetTimeout(0)
        FuzzCoverageEndInput()
        return (accepted, FuzzCoverageNewFeatures(1))
    }
}

/// A worker: replays the seeds and the corpus, then mutates until `deadline`, saving each input
/// that hits a new feature. A crash kills it; the supervisor finds the input in `pending`.
@MainActor func runWorker(
    _ target: FuzzTarget, _ folders: FuzzFolders, work: URL, until deadline: Date, seed: UInt64
)
    throws
{
    guard FuzzCoverageInstallCrashHandler(folders.pending.path) == 0 else {
        throw FuzzError("the crash file's path is too long: \(folders.pending.path)")
    }
    try FileManager.default.createDirectory(at: folders.corpus, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let run = try target.prepare(work)
    guard FuzzCoverageEdgeCount() > 0 else {
        throw FuzzError(
            "no coverage: build with -sanitize-coverage=edge,trace-pc-guard (scripts/fuzz)")
    }
    var corpus: [[UInt8]] = []
    for folder in [folders.seeds, folders.corpus] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        for name in names {
            let input = [UInt8](try Data(contentsOf: folder.appendingPathComponent(name)))
            if execute(input, run).features > 0 || folder == folders.corpus { corpus.append(input) }
        }
    }
    if corpus.isEmpty { corpus = [[]] }
    let tokens = target.tokens.map { Array($0.utf8) } + harvestTokens(corpus)
    var mutator = Mutator(
        seed: seed, maximumBytes: maximumInputBytes, tokens: tokens)
    var executions = 0
    var accepted = 0
    let started = Date()
    var nextReport = started.addingTimeInterval(30)
    report(target, executions: 0, accepted: 0, corpus: corpus.count, since: started)
    while Date() < deadline {
        let base = mutator.random.pick(corpus)
        let other = mutator.random.pick(corpus)
        let input = mutator.mutate(base, splicing: other)
        let result = execute(input, run)
        executions += 1
        if result.accepted { accepted += 1 }
        if result.features > 0 {
            corpus.append(input)
            try Data(input).write(to: folders.corpus.appendingPathComponent(inputName(input)))
        }
        if Date() >= nextReport {
            report(
                target, executions: executions, accepted: accepted, corpus: corpus.count,
                since: started)
            nextReport = nextReport.addingTimeInterval(30)
        }
    }
    report(target, executions: executions, accepted: accepted, corpus: corpus.count, since: started)
}

private func report(
    _ target: FuzzTarget, executions: Int, accepted: Int, corpus: Int, since started: Date
) {
    let seconds = Date().timeIntervalSince(started)
    let rate = seconds > 0 ? Double(executions) / seconds : 0
    let share = executions > 0 ? 100 * Double(accepted) / Double(executions) : 0
    printError(
        String(
            format:
                "%@: %.0f s, %d inputs (%.0f/s, %.0f%% accepted), corpus %d, %d features of %d edges",
            target.name, seconds, executions, rate, share, corpus, FuzzCoverageFeatureCount(),
            FuzzCoverageEdgeCount()))
}

func printError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
