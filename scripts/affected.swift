// Prints the test targets that changed files can affect, one per line, for ./scripts/test.
// Paths come on standard input, one per line, relative to the repo root. A path inside a target's
// folder affects every test target that depends on that target, directly or through other
// targets. Package.swift is the source of that graph. A path in `shared` can change how every
// test builds or runs, so it prints `all`. Any other path outside Sources and Tests affects no
// test, unless `readByTests` names it.
//
//   swift scripts/affected.swift            the affected test targets, or `all`
//   swift scripts/affected.swift --inputs   every path a test can read, as git pathspecs
//
// Exits 1 for a path under Sources or Tests that is in no target's folder: a file there that no
// target builds means Package.swift and the tree disagree.
import Foundation

/// The package graph, the toolchain, and the scripts that pick and run the tests.
let shared: Set<String> = [
    "Package.swift", "Package.resolved", ".xcode-version", "scripts/test", "scripts/affected.swift",
]

/// Files outside every target's folder that a test reads, with the test target that reads them.
let readByTests: [String: String] = ["docs/plan.md": "BenchTests"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("affected: \(message)\n".data(using: .utf8)!)
    exit(1)
}

if CommandLine.arguments.dropFirst() == ["--inputs"] {
    print(
        (["Sources", "Tests"] + shared.sorted() + readByTests.keys.sorted()).joined(separator: "\n")
    )
    exit(0)
}
guard CommandLine.arguments.count == 1 else { fail("usage: affected.swift [--inputs]") }

var paths: [String] = []
while let line = readLine() {
    if !line.isEmpty { paths.append(line) }
}
if paths.contains(where: shared.contains) {
    print("all")
    exit(0)
}

let dump = Process()
dump.executableURL = URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
dump.arguments = ["swift", "package", "dump-package"]
let pipe = Pipe()
dump.standardOutput = pipe
try dump.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
dump.waitUntilExit()
guard dump.terminationStatus == 0 else { fail("swift package dump-package failed") }

let package = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let targets = package["targets"] as! [[String: Any]]

var folder: [String: String] = [:]
var dependencies: [String: [String]] = [:]
var tests: [String] = []
for target in targets {
    let name = target["name"] as! String
    let isTest = target["type"] as? String == "test"
    if isTest { tests.append(name) }
    folder[name] = target["path"] as? String ?? (isTest ? "Tests/\(name)" : "Sources/\(name)")
    // byName and target dependencies are [name, condition]; products are external packages.
    dependencies[name] = (target["dependencies"] as? [[String: Any]] ?? []).compactMap {
        (($0["byName"] ?? $0["target"]) as? [Any])?.first as? String
    }
}

var hit: Set<String> = []
for path in paths {
    if let reader = readByTests[path] {
        hit.insert(reader)
        continue
    }
    guard path.hasPrefix("Sources/") || path.hasPrefix("Tests/") else { continue }
    guard let owner = folder.first(where: { path.hasPrefix($0.value + "/") })?.key else {
        fail("\(path) is in no target's folder in Package.swift")
    }
    hit.insert(owner)
}

/// Whether `target` is in `hit` or depends on a target that is, through any chain.
var reaches: [String: Bool] = [:]
func reachesHit(_ target: String) -> Bool {
    if let known = reaches[target] { return known }
    let result =
        hit.contains(target) || dependencies[target, default: []].contains(where: reachesHit)
    reaches[target] = result
    return result
}

for test in tests.sorted() where reachesHit(test) { print(test) }
