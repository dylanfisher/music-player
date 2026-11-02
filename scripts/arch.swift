// Enforces the tier dependency direction from docs/map.md. Package.swift is the source of the
// dependency graph: the compiler already rejects an import a target hasn't declared, so checking
// declared dependencies here covers every import.
//
// It also fails any `fileURLWithPath:` call without `isDirectory:` under Sources. Without it
// Foundation stats the path to learn whether it is a directory, and on an SMB share that wait
// blocks the calling thread for seconds. `--urls-only <root>` runs just that rule on another
// tree, for scripts/arch-test.
import Foundation

/// Where in `text` a `fileURLWithPath` call has no `isDirectory:` argument, as 1-based lines.
/// A call is the text up to the parenthesis that closes it; a bare `URL.init(fileURLWithPath:)`
/// reference has no arguments, so it always fails.
func statCalls(in text: String) -> [Int] {
    let chars = Array(text)
    let needle = Array("fileURLWithPath")
    var lines: [Int] = []
    var line = 1
    var index = 0
    while index < chars.count {
        if chars[index] == "\n" { line += 1 }
        guard chars[index...].starts(with: needle) else {
            index += 1
            continue
        }
        var depth = 0
        var end = index
        while end < chars.count {
            if chars[end] == "(" { depth += 1 }
            if chars[end] == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            end += 1
        }
        if !String(chars[index..<end]).contains("isDirectory:") { lines.append(line) }
        index += needle.count
    }
    return lines
}

func statProblems(root: String) -> [String] {
    var problems: [String] = []
    let walk = FileManager.default.enumerator(atPath: root)
    while let relative = walk?.nextObject() as? String {
        guard relative.hasSuffix(".swift") else { continue }
        let path = root + "/" + relative
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            problems.append("\(path): unreadable")
            continue
        }
        for line in statCalls(in: text) {
            problems.append("\(path):\(line): fileURLWithPath without isDirectory: stats the path")
        }
    }
    return problems
}

func finish(_ problems: [String], _ success: String) -> Never {
    if problems.isEmpty {
        print(success)
        exit(0)
    }
    FileHandle.standardError.write(
        problems.joined(separator: "\n").appending("\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--urls-only" {
    finish(statProblems(root: arguments[2]), "no fileURLWithPath stats a path")
}

// Tier -> tiers it may depend on. Must match the Tiers table in docs/map.md.
let allowed: [String: Set<String>] = [
    "Primitives": [],
    "Core": ["Primitives", "Core"],
    "Features": ["Primitives", "Core"],
    "App": ["Primitives", "Core", "Features"],
    "Tools": ["Primitives", "Core", "Features", "Tools"],
]

let dump = Process()
dump.executableURL = URL(fileURLWithPath: "/usr/bin/env")
dump.arguments = ["swift", "package", "dump-package"]
let pipe = Pipe()
dump.standardOutput = pipe
try dump.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
dump.waitUntilExit()
guard dump.terminationStatus == 0 else { fatalError("swift package dump-package failed") }

let package = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let targets = package["targets"] as! [[String: Any]]

var tierOf: [String: String] = [:]
var problems: [String] = []
for target in targets where target["type"] as? String != "test" {
    let name = target["name"] as! String
    let parts = (target["path"] as? String ?? "").split(separator: "/").map(String.init)
    if parts.count == 3, parts[0] == "Sources", allowed[parts[1]] != nil, parts[2] == name {
        tierOf[name] = parts[1]
    } else {
        problems.append(
            "\(name): path must be Sources/<\(allowed.keys.sorted().joined(separator: "|"))>/\(name)"
        )
    }
}

for target in targets where target["type"] as? String != "test" {
    let name = target["name"] as! String
    guard let tier = tierOf[name] else { continue }
    for dependency in target["dependencies"] as? [[String: Any]] ?? [] {
        // byName and target dependencies are [name, condition]; products are external packages.
        guard let entry = (dependency["byName"] ?? dependency["target"]) as? [Any],
            let other = entry.first as? String, let otherTier = tierOf[other]
        else { continue }
        if !allowed[tier]!.contains(otherTier) {
            problems.append("\(name) (\(tier)) may not depend on \(other) (\(otherTier))")
        }
    }
}

problems += statProblems(root: "Sources")
finish(problems, "\(tierOf.count) targets, dependency direction holds, no URL stats a path")
