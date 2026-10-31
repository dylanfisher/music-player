// Enforces the tier dependency direction from docs/map.md. Package.swift is the source of the
// dependency graph: the compiler already rejects an import a target hasn't declared, so checking
// declared dependencies here covers every import.
import Foundation

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

if problems.isEmpty {
    print("\(tierOf.count) targets, dependency direction holds")
} else {
    FileHandle.standardError.write(
        problems.joined(separator: "\n").appending("\n").data(using: .utf8)!)
    exit(1)
}
