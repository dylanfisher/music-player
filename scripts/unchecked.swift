// Fails an `@unchecked Sendable` or a `nonisolated(unsafe)` under Sources whose comment doesn't
// name what keeps it safe: a lock, a queue, a semaphore, a condition, a serial order, the main
// actor, queue or thread, one thread, a value set once, or an immutable one (ADR 0201). The
// comment is on the site's line, after the code, or in the run of `//` lines just above it, a
// doc comment included; when the site continues a declaration begun on an earlier line, such as
// one under an attribute, the run above any of its lines counts. A script can only see that a
// guard is named, not that it guards: the review reads the rest.
//
// A file whose sites name no guard yet is listed in scripts/unchecked-allow.txt with their count,
// which only goes down, and an entry whose file has none fails.
//
//   swift scripts/unchecked.swift [--root <dir>]
//
// <dir> (default: the current directory) holds Sources/ and scripts/unchecked-allow.txt. Exits 1
// on a site outside the allowlist that names no guard, on an entry with too few sites or none,
// or on a malformed entry.
import Foundation

let allowFile = "scripts/unchecked-allow.txt"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("unchecked: \(message)\n".utf8))
    exit(2)
}

var root = FileManager.default.currentDirectoryPath
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    switch flag {
    case "--root":
        guard let value = arguments.popFirst(), !value.hasPrefix("--") else {
            fail("--root needs a directory")
        }
        root = value
    default:
        fail("unknown argument \(flag); usage: swift scripts/unchecked.swift [--root <dir>]")
    }
}

// MARK: - Lines

/// A line split into its code, with the text of its string literals blanked, and its trailing
/// `//` comment. A line that is only a comment has empty code.
func split(_ line: Substring) -> (code: String, comment: String?) {
    let chars = Array(line)
    var code: [Character] = []
    var inString = false
    var index = 0
    while index < chars.count {
        let char = chars[index]
        if inString {
            if char == "\\" { index += 1 } else if char == "\"" { inString = false }
            code.append(inString ? " " : char)
        } else if char == "\"" {
            inString = true
            code.append(char)
        } else if char == "/", index + 1 < chars.count, chars[index + 1] == "/" {
            let comment = String(chars[(index + 2)...]).drop { $0 == "/" }
            return (
                String(code).trimmingCharacters(in: .whitespaces),
                comment.trimmingCharacters(in: .whitespaces)
            )
        } else {
            code.append(char)
        }
        index += 1
    }
    return (String(code).trimmingCharacters(in: .whitespaces), nil)
}

/// Whether `current` goes on with a statement that `previous`, the code line above it, began:
/// the previous line ends mid-expression or is an attribute, or the current one starts with an
/// operator or a member.
func continues(_ previous: String, _ current: String) -> Bool {
    let openEnds = [",", "(", "[", "=", "&&", "||", "??", "->", "guard", "if", "while", "return"]
    let openStarts = [".", "&&", "||", "??", "?", ")", "]"]
    return openEnds.contains { previous.hasSuffix($0) } || previous.hasPrefix("@")
        || openStarts.contains { current.hasPrefix($0) }
}

/// Whether the site on line `site` (0-based) of `lines` has a comment that `explains` accepts:
/// its own, or the `//` run above it or above any earlier line of its statement.
func explained(
    _ lines: [(code: String, comment: String?)], _ site: Int, _ explains: (String) -> Bool
)
    -> Bool
{
    var line = site
    while true {
        if let comment = lines[line].comment, explains(comment) { return true }
        var above = line - 1
        var run: [String] = []
        while above >= 0, lines[above].code.isEmpty, let comment = lines[above].comment {
            run.insert(comment, at: 0)
            above -= 1
        }
        if !run.isEmpty, explains(run.joined(separator: " ")) { return true }
        guard above >= 0, !lines[above].code.isEmpty,
            continues(lines[above].code, lines[line].code)
        else { return false }
        line = above
    }
}

// MARK: - Sites

let pattern = try! NSRegularExpression(pattern: #"@unchecked\s+Sendable|\bnonisolated\(unsafe\)"#)
/// The words that name a guard, as a word or as the end of a name such as `stateLock`.
let guards = try! NSRegularExpression(
    pattern: #"(?i:\b(lock|queue|semaphore|condition|serial|main (actor|queue|thread)|one thread"#
        + #"|set once|immutable))|(Lock|Queue|Semaphore|Condition)\b"#)

/// Whether `comment` names a guard.
func namesGuard(_ comment: String) -> Bool {
    guards.firstMatch(in: comment, range: NSRange(comment.startIndex..., in: comment)) != nil
}

/// Each Swift file's sites that name no guard, as 1-based lines, by its path from `root`.
var sites: [String: [Int]] = [:]
var total = 0
guard let walker = FileManager.default.enumerator(atPath: root + "/Sources") else {
    fail("can't read \(root)/Sources")
}
while let relative = walker.nextObject() as? String {
    guard relative.hasSuffix(".swift") else { continue }
    let path = "Sources/" + relative
    guard let data = FileManager.default.contents(atPath: root + "/" + path) else {
        fail("can't read \(path)")
    }
    let lines = String(decoding: data, as: UTF8.self).split(
        separator: "\n", omittingEmptySubsequences: false
    ).map(split)
    for (index, line) in lines.enumerated() {
        let range = NSRange(line.code.startIndex..., in: line.code)
        guard pattern.firstMatch(in: line.code, range: range) != nil else { continue }
        total += 1
        if !explained(lines, index, namesGuard) { sites[path, default: []].append(index + 1) }
    }
}

// MARK: - Allowlist

// One entry per line, `<file> | <count> | <reason>`; `#` starts a comment line.
guard let allowData = FileManager.default.contents(atPath: root + "/" + allowFile) else {
    fail("can't read \(allowFile)")
}
var problems: [String] = []
var notes: [String] = []
var counts: [String: (count: Int, line: Int)] = [:]
for (offset, raw) in String(decoding: allowData, as: UTF8.self).components(separatedBy: "\n")
    .enumerated()
{
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let at = "\(allowFile):\(offset + 1):"
    let parts = line.components(separatedBy: " | ").map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    guard parts.count == 3, !parts[0].contains(" "), let count = Int(parts[1]), count > 0,
        !parts[2].isEmpty
    else {
        problems.append("\(at) expected `<file> | <count> | <reason>`")
        continue
    }
    let path = parts[0]
    if let first = counts[path] {
        problems.append("\(at) repeats line \(first.line)")
        continue
    }
    counts[path] = (count, offset + 1)
    let found = sites[path]?.count ?? 0
    if found == 0 {
        problems.append("\(at) \(path) has no site that names no guard, delete the entry")
    } else if found > count {
        problems.append(
            "\(at) \(path) has \(found) sites that name no guard, over its \(count): name it at"
                + " each new one; they're at lines \(sites[path]!.map(String.init).joined(separator: ", "))"
        )
    } else if found < count {
        notes.append(
            "\(at) \(path) has \(found) sites that name no guard: lower its count to \(found)")
    }
}

for (path, lines) in sites.sorted(by: { $0.key < $1.key }) where counts[path] == nil {
    for line in lines {
        problems.append(
            "\(path):\(line): no comment names the lock, queue or other guard that makes it safe")
    }
}

for note in notes { print(note) }
if !problems.isEmpty {
    for problem in problems { print(problem) }
    exit(1)
}
print(
    "\(total) unchecked sendables, each naming its guard or allowlisted"
        + " (\(counts.count) entries)")
