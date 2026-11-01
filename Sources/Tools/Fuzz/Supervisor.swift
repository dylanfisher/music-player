import Foundation

/// The most crashes one run keeps before it stops: past a few, they're mostly the same bug.
let maximumCrashes = 10
/// Replays minimising one crash may take.
let minimiseAttempts = 400

/// How a worker or a replay ended.
enum Outcome: Equatable {
    case finished
    /// It failed before running an input: a bad setup, not a finding.
    case failed(Int32)
    case crashed(signal: Int32)

    var description: String {
        switch self {
        case .finished: "finished"
        case .failed(let status): "exited with status \(status)"
        case .crashed(let signal) where signal == SIGALRM:
            "hung for more than \(inputTimeoutSeconds) s"
        case .crashed(let signal):
            "crashed with signal \(signal) (\(String(cString: strsignal(signal))))"
        }
    }
}

/// Fuzzes `target` for `seconds` in workers it restarts after each crash, and minimises and
/// saves every crash. Returns the crash files.
@MainActor func supervise(
    _ target: FuzzTarget, _ folders: FuzzFolders, seconds: Double, clones: URL?, seed: UInt64
)
    throws -> [URL]
{
    let work = try fuzzCaches().appendingPathComponent(target.name)
    try? FileManager.default.removeItem(at: work)
    try? FileManager.default.removeItem(at: folders.seeds)
    for folder in [work, folders.seeds, folders.corpus, folders.crashes] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let seeds = try seedInputs(for: target, clones: clones, work: work)
    for input in seeds {
        try Data(input).write(to: folders.seeds.appendingPathComponent(inputName(input)))
    }
    printError("\(target.name): \(seeds.count) seeds, fuzzing for \(Int(seconds)) s")
    let deadline = Date().addingTimeInterval(seconds)
    var crashes: [URL] = []
    var workerSeed = seed
    while Date() < deadline, crashes.count < maximumCrashes {
        try? FileManager.default.removeItem(at: folders.pending)
        let outcome = try spawn(
            [
                FuzzMode.worker.rawValue, target.name, FuzzFlag.output, folders.output.path,
                FuzzFlag.until, String(deadline.timeIntervalSince1970), FuzzFlag.seed,
                String(workerSeed),
            ])
        workerSeed &+= 1
        switch outcome {
        case .finished: break
        case .failed:
            throw FuzzError("the \(target.name) worker \(outcome.description)")
        case .crashed:
            guard let input = try? [UInt8](Data(contentsOf: folders.pending)) else {
                throw FuzzError("the \(target.name) worker \(outcome.description) outside an input")
            }
            crashes.append(try save(input, outcome, target, folders))
        }
    }
    return crashes
}

/// Minimises a crashing input against the same outcome, saves it and its report, and prints the
/// report's start.
private func save(
    _ input: [UInt8], _ outcome: Outcome, _ target: FuzzTarget, _ folders: FuzzFolders
)
    throws -> URL
{
    printError(
        "\(target.name): an input of \(input.count) bytes \(outcome.description); minimising")
    let minimised = minimise(input, attempts: minimiseAttempts) { candidate in
        do {
            try Data(candidate).write(to: folders.candidate)
            return try replay(target, folders.candidate, log: nil) == outcome
        } catch {
            preconditionFailure("can't replay \(folders.candidate.path): \(error)")
        }
    }
    let file = folders.crashes.appendingPathComponent("crash-\(inputName(minimised))")
    try Data(minimised).write(to: file)
    let log = file.appendingPathExtension("log")
    let final = try replay(target, file, log: log)
    let report = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    printError(
        "\(target.name): saved \(file.path) (\(minimised.count) bytes, \(final.description))\n"
            + report.split(separator: "\n").prefix(20).joined(separator: "\n"))
    return file
}

/// Runs one input in a child process, its standard error to `log` or discarded.
func replay(_ target: FuzzTarget, _ file: URL, log: URL?) throws -> Outcome {
    try spawn([FuzzMode.replay.rawValue, target.name, file.path], standardError: log)
}

/// Runs this tool again with `arguments`, with the sanitizer and hashing settings that make a
/// crash repeat.
private func spawn(_ arguments: [String], standardError log: URL? = nil) throws -> Outcome {
    guard let executable = Bundle.main.executableURL else {
        throw FuzzError("can't find this tool's own executable")
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    // Abort on a report so the crash handler sees it; refuse allocations a size field drove
    // past what any real file needs.
    let sanitizer = "abort_on_error=1:detect_leaks=0:max_allocation_size_mb=2048"
    environment["ASAN_OPTIONS"] = [environment["ASAN_OPTIONS"], sanitizer].compactMap { $0 }
        .joined(separator: ":")
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    process.environment = environment
    if let log {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
    } else if arguments.first == FuzzMode.replay.rawValue {
        process.standardError = FileHandle.nullDevice
    }
    if arguments.first == FuzzMode.replay.rawValue {
        process.standardOutput = FileHandle.nullDevice
    }
    try process.run()
    process.waitUntilExit()
    switch process.terminationReason {
    case .uncaughtSignal: return .crashed(signal: process.terminationStatus)
    case .exit:
        return process.terminationStatus == 0 ? .finished : .failed(process.terminationStatus)
    @unknown default: return .failed(process.terminationStatus)
    }
}
