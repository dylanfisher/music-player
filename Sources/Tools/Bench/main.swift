import Foundation

// Runs the benchmarks and exits non-zero if any misses its budget or fails:
//   Bench [--list] [--soak <seconds>] [<part of a name>...]

var arguments = Array(CommandLine.arguments.dropFirst())
if let index = arguments.firstIndex(of: "--soak") {
    guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]), seconds > 0
    else {
        FileHandle.standardError.write(Data("error: --soak needs a number of seconds\n".utf8))
        exit(1)
    }
    soakSeconds = seconds
    arguments.removeSubrange(index...index + 1)
}
if arguments.contains("--list") {
    for benchmark in benchmarks { print(benchmark.name) }
    exit(0)
}
let selected =
    arguments.isEmpty
    ? benchmarks
    : benchmarks.filter { benchmark in arguments.contains { benchmark.name.contains($0) } }
guard !selected.isEmpty else {
    FileHandle.standardError.write(Data("error: no benchmark matches \(arguments)\n".utf8))
    exit(1)
}

let machine = MachineClass.current
let results = run(selected, on: machine) { name in
    FileHandle.standardError.write(Data("running \(name)…\n".utf8))
}
print(table(results, machine: machine))
exit(results.allSatisfy(\.passed) ? 0 : 1)
