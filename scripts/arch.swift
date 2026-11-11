// Enforces the tier dependency direction from docs/map.md. Package.swift is the source of the
// dependency graph: the compiler already rejects an import a target hasn't declared, so checking
// declared dependencies here covers every import.
//
// It also fails any `fileURLWithPath:` call without `isDirectory:` under Sources. Without it
// Foundation stats the path to learn whether it is a directory, and on an SMB share that wait
// blocks the calling thread for seconds. `--urls-only <root>` runs just that rule on another
// tree, for scripts/arch-test.
//
// And it fails an `import AppKit` in a Core module other than those in `appKitCore`: Core is
// the domain, testable without a window, except for the bars' column views (ADR 0085), which
// two features share. `--appkit-only <core root>` runs just that rule, for scripts/arch-test.
//
// And it fails a log interpolation that marks a path or URL `privacy: .public` (ADR 0118).
// `--log-paths-only <root>` runs just that rule, for scripts/arch-test.
//
// `--map-only <root>` checks <root>/docs/map.md against the tree, for the map step of
// ./scripts/check: each backticked path under `mapPathRoots` exists (one with `<`, `>`, `*` or
// `{` is a placeholder), the Tiers table's rows are the keys of `allowed` and the folders under
// Sources, and each `Sources/<Tier>/<Name>` folder is a target's path in the package.
import Foundation

// Tier -> tiers it may depend on. The Tiers table in docs/map.md has a row
// for each, which `--map-only` checks.
let allowed: [String: Set<String>] = [
    "Primitives": [],
    "Core": ["Primitives", "Core"],
    "Features": ["Primitives", "Core"],
    "App": ["Primitives", "Core", "Features"],
    "Tools": ["Primitives", "Core", "Features", "Tools"],
]

/// The roots a backticked path in docs/map.md is checked under.
let mapPathRoots = ["Sources/", "Tests/", "scripts/", "docs/", "Support/"]

/// The Core modules that may import AppKit.
let appKitCore: Set<String> = ["BarView"]

/// Where a Core module outside `appKitCore` imports AppKit, under `root`, the Core tier's folder.
func appKitProblems(root: String) -> [String] {
    var problems: [String] = []
    let walk = FileManager.default.enumerator(atPath: root)
    while let relative = walk?.nextObject() as? String {
        guard relative.hasSuffix(".swift"),
            let module = relative.split(separator: "/").first.map(String.init),
            !appKitCore.contains(module)
        else { continue }
        let path = root + "/" + relative
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            problems.append("\(path): unreadable")
            continue
        }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            // Code before a `//` comment, split on spaces, tabs and the `;` that can end it.
            let code = line.components(separatedBy: "//")[0]
            let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" })
            guard let at = words.firstIndex(of: "import"), at + 1 < words.count else { continue }
            // `import AppKit`, `import AppKit.NSView`, `import class AppKit.NSView`, and Cocoa,
            // which re-exports AppKit.
            let named = words[(at + 1)...].contains { word in
                ["AppKit", "Cocoa"].contains { word == $0 || word.hasPrefix($0 + ".") }
            }
            if named {
                problems.append(
                    "\(path):\(index + 1): \(module) is Core and may not import AppKit")
            }
        }
    }
    return problems
}

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

/// Where a log interpolation marks a path or URL public, under `root`: the log keeps paths
/// private, hashed where lines about one file need matching (ADRs 0025 and 0118). An
/// interpolation is the text from `\(` to the parenthesis that closes it, on one line; one of
/// `logText(_:without:)` passes, as it takes the path only to leave it out.
func logPathProblems(root: String) -> [String] {
    var problems: [String] = []
    let named = try! NSRegularExpression(pattern: "\\b[A-Za-z]*(path|Path|url|Url|URL)\\b")
    let walk = FileManager.default.enumerator(atPath: root)
    while let relative = walk?.nextObject() as? String {
        guard relative.hasSuffix(".swift") else { continue }
        let path = root + "/" + relative
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            problems.append("\(path): unreadable")
            continue
        }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let chars = Array(line)
            var start = 0
            while start + 1 < chars.count {
                guard chars[start] == "\\", chars[start + 1] == "(" else {
                    start += 1
                    continue
                }
                var depth = 0
                var end = start + 1
                while end < chars.count {
                    if chars[end] == "(" { depth += 1 }
                    if chars[end] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    end += 1
                }
                let interpolation = String(chars[start..<min(end + 1, chars.count)])
                let range = NSRange(interpolation.startIndex..., in: interpolation)
                // `logText(_:without:)` takes the path to leave it out.
                if interpolation.contains("privacy: .public"),
                    !interpolation.hasPrefix("\\(logText("),
                    named.firstMatch(in: interpolation, range: range) != nil
                {
                    problems.append("\(path):\(index + 1): a path or URL is logged public")
                }
                start = end
            }
        }
    }
    return problems
}

/// The non-test targets' names, paths and dependencies, from `swift package dump-package` run in `root`.
func targetPaths(root: String) -> [(name: String, path: String, dependencies: [String])] {
    let dump = Process()
    dump.executableURL = URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
    dump.arguments = ["swift", "package", "dump-package"]
    dump.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
    let pipe = Pipe()
    dump.standardOutput = pipe
    do { try dump.run() } catch { fatalError("can't run swift package dump-package: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    dump.waitUntilExit()
    guard dump.terminationStatus == 0,
        let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let targets = package["targets"] as? [[String: Any]]
    else { fatalError("swift package dump-package failed in \(root)") }
    return targets.filter { $0["type"] as? String != "test" }.map { target in
        let dependencies = (target["dependencies"] as? [[String: Any]] ?? []).compactMap {
            // byName and target dependencies are [name, condition]; products are external.
            (($0["byName"] ?? $0["target"]) as? [Any])?.first as? String
        }
        return (target["name"] as! String, target["path"] as? String ?? "", dependencies)
    }
}

/// What docs/map.md under `root` gets wrong about the tree: a backticked path under one of
/// `mapPathRoots` that doesn't exist, a Tiers row whose tier `allowed` doesn't have, a tier of
/// `allowed` or a folder under Sources with no row, and a module folder that no target's path
/// names. The map lists no modules (it holds conventions, not an inventory), so the package is
/// what a module folder is checked against.
func mapProblems(root: String, targets: [String]) -> [String] {
    let file = "docs/map.md"
    guard let text = try? String(contentsOfFile: root + "/" + file, encoding: .utf8) else {
        return ["\(file): unreadable"]
    }
    var problems: [String] = []
    let lines = text.components(separatedBy: "\n")
    let token = try! NSRegularExpression(pattern: "`([^`]+)`")
    for (index, line) in lines.enumerated() {
        let range = NSRange(line.startIndex..., in: line)
        for match in token.matches(in: line, range: range) {
            let path = String(line[Range(match.range(at: 1), in: line)!])
            guard mapPathRoots.contains(where: { path.hasPrefix($0) }),
                !path.contains(where: { "<>*{".contains($0) })
            else { continue }
            if !FileManager.default.fileExists(atPath: root + "/" + path) {
                problems.append("\(file):\(index + 1): `\(path)` does not exist")
            }
        }
    }
    // The Tiers table's rows: `| **<tier>** | `Sources/<Tier>` | … |`, under `## Tiers`.
    var rows: [String: Int] = [:]
    var inTiers = false
    for (index, line) in lines.enumerated() {
        if line.hasPrefix("## ") { inTiers = line == "## Tiers" }
        guard inTiers, line.hasPrefix("| **") else { continue }
        let cells = line.components(separatedBy: " | ")
        guard cells.count > 2, cells[1].hasPrefix("`Sources/"), cells[1].hasSuffix("`") else {
            problems.append("\(file):\(index + 1): a Tiers row's path isn't `Sources/<Tier>`")
            continue
        }
        let tier = String(cells[1].dropFirst("`Sources/".count).dropLast())
        rows[tier] = index + 1
        if allowed[tier] == nil {
            problems.append(
                "\(file):\(index + 1): tier \(tier) isn't a key of allowed in scripts/arch.swift")
        }
    }
    if rows.isEmpty {
        return problems + ["\(file): no rows found in the Tiers table under ## Tiers"]
    }
    for tier in allowed.keys.sorted() where rows[tier] == nil {
        problems.append("\(file): no Tiers row for \(tier), which scripts/arch.swift allows")
    }
    let sources = root + "/Sources"
    let folders = { (path: String) -> [String] in
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { name in
            var isFolder: ObjCBool = false
            return !name.hasPrefix(".")
                && FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &isFolder)
                && isFolder.boolValue
        }.sorted()
    }
    let named = Set(targets)
    for tier in folders(sources) {
        if rows[tier] == nil {
            problems.append(
                "Sources/\(tier): a tier folder with no row in the Tiers table of \(file)")
        }
        for module in folders(sources + "/" + tier)
        where !named.contains("Sources/\(tier)/\(module)") {
            problems.append(
                "Sources/\(tier)/\(module): a module folder that no target in Package.swift has as"
                    + " its path")
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
if arguments.count == 3, arguments[1] == "--appkit-only" {
    finish(appKitProblems(root: arguments[2]), "no Core module but BarView imports AppKit")
}
if arguments.count == 3, arguments[1] == "--log-paths-only" {
    finish(logPathProblems(root: arguments[2]), "no path is logged public")
}
if arguments.count == 3, arguments[1] == "--map-only" {
    let root = arguments[2]
    finish(
        mapProblems(root: root, targets: targetPaths(root: root).map(\.path)),
        "docs/map.md's paths exist, and its tiers match allowed, Sources and Package.swift")
}

let targets = targetPaths(root: ".")
var tierOf: [String: String] = [:]
var problems: [String] = []
for target in targets {
    let parts = target.path.split(separator: "/").map(String.init)
    if parts.count == 3, parts[0] == "Sources", allowed[parts[1]] != nil, parts[2] == target.name {
        tierOf[target.name] = parts[1]
    } else {
        problems.append(
            "\(target.name): path must be"
                + " Sources/<\(allowed.keys.sorted().joined(separator: "|"))>/\(target.name)")
    }
}

for target in targets {
    guard let tier = tierOf[target.name] else { continue }
    for other in target.dependencies {
        guard let otherTier = tierOf[other] else { continue }
        if !allowed[tier]!.contains(otherTier) {
            problems.append("\(target.name) (\(tier)) may not depend on \(other) (\(otherTier))")
        }
    }
}

problems += statProblems(root: "Sources")
problems += appKitProblems(root: "Sources/Core")
problems += logPathProblems(root: "Sources")
finish(
    problems,
    "\(tierOf.count) targets, dependency direction holds, no URL stats a path, AppKit only in"
        + " \(appKitCore.sorted().joined(separator: ", ")) of Core, no path logged public")
