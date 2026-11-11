import CommandLineErrors
import Foundation

// A coverage-guided fuzzer for the parsers and the tag writer (ADR 0027). scripts/fuzz builds it
// with the coverage hooks and AddressSanitizer and runs it:
//   Fuzz --list
//   Fuzz run <target> <seconds> --output <folder> [--clones <folder>] [--seed <n>]
//   Fuzz replay <target> <file>...
// `run` supervises workers (`Fuzz worker`, which it starts itself) and saves each crash,
// minimised, under <folder>/crashes. It exits 1 if it found any.

/// Exits 2, apart from the 1 that `run` exits with when it found a crash.
func fail(_ message: String) -> Never {
    CommandLineErrors.fail(message, exitCode: 2)
}

/// The value after `flag`, which must be there and not be another flag.
func value(_ flag: String, in arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
        fail("\(flag) needs a value")
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

func target(_ name: String) -> FuzzTarget {
    guard let target = FuzzTarget.named(name) else {
        fail("no target \(name); one of \(FuzzTarget.all.map(\.name).joined(separator: ", "))")
    }
    return target
}

var arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.isEmpty ? nil : FuzzMode(rawValue: arguments.removeFirst())
let output = value(FuzzFlag.output, in: &arguments).map {
    URL(fileURLWithPath: $0, isDirectory: true)
}
let clones = value(FuzzFlag.clones, in: &arguments).map {
    URL(fileURLWithPath: $0, isDirectory: true)
}
let seed = value(FuzzFlag.seed, in: &arguments).map { text in
    guard let seed = UInt64(text) else { fail("--seed needs a whole number, not \(text)") }
    return seed
}
let until = value(FuzzFlag.until, in: &arguments).map { text in
    guard let seconds = Double(text) else { fail("--until needs a time, not \(text)") }
    return Date(timeIntervalSince1970: seconds)
}
if let flag = arguments.first(where: { $0.hasPrefix("--") }) { fail(FlagMessage.unknown(flag)) }

do {
    switch mode {
    case .list:
        guard arguments.isEmpty else { fail("--list takes nothing else") }
        for target in FuzzTarget.all { print("\(target.name)\t\(target.summary)") }
    case .run:
        guard arguments.count == 2, let seconds = Double(arguments[1]), seconds > 0 else {
            fail("run needs a target and a number of seconds")
        }
        guard let output else { fail("run needs --output") }
        let target = target(arguments[0])
        let crashes = try supervise(
            target, FuzzFolders(output: output), seconds: seconds, clones: clones, seed: seed ?? 1)
        printError("\(target.name): \(crashes.count) crashes in \(Int(seconds)) s")
        exit(crashes.isEmpty ? 0 : 1)
    case .worker:
        guard arguments.count == 1, let output, let until, let seed else {
            fail("worker needs a target, --output, --until and --seed")
        }
        let target = target(arguments[0])
        try runWorker(
            target, FuzzFolders(output: output),
            work: try fuzzCaches().appendingPathComponent(target.name), until: until, seed: seed)
    case .replay:
        guard arguments.count >= 2 else { fail("replay needs a target and at least one file") }
        let target = target(arguments[0])
        let run = try target.prepare(try fuzzCaches().appendingPathComponent(target.name))
        for path in arguments.dropFirst() {
            let input = [UInt8](
                try Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false)))
            let result = execute(input, run)
            print("\(path): \(result.accepted ? "accepted" : "refused")")
        }
    case nil:
        fail("the first argument is \(FuzzMode.list.rawValue), run, worker or replay")
    }
} catch {
    fail("\(error)")
}
