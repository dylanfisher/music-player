// Fails a Swift file under Sources longer than `limit` lines, so a typical change reads one small
// file and two phases rarely edit the same one (phase 84, ADR 0201). A file already over it is
// listed in scripts/size-allow.txt with a ceiling, its length when it was listed, which a split
// or a cut brings down and nothing raises.
//
//   swift scripts/size.swift [--root <dir>]
//
// <dir> (default: the current directory) holds Sources/ and scripts/size-allow.txt. Exits 1 on a
// file over its limit or ceiling, on an entry for a file at or under the limit or missing, or on
// a malformed entry.
import Foundation

let limit = 1000
let allowFile = "scripts/size-allow.txt"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("size: \(message)\n".utf8))
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
        fail("unknown argument \(flag); usage: swift scripts/size.swift [--root <dir>]")
    }
}

/// Each Swift file's line count, by its path from `root`.
var lengths: [String: Int] = [:]
guard let walker = FileManager.default.enumerator(atPath: root + "/Sources") else {
    fail("can't read \(root)/Sources")
}
while let relative = walker.nextObject() as? String {
    guard relative.hasSuffix(".swift") else { continue }
    let path = "Sources/" + relative
    guard let data = FileManager.default.contents(atPath: root + "/" + path) else {
        fail("can't read \(path)")
    }
    lengths[path] = data.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
}

// One entry per line, `<path> <ceiling> | <reason>`; `#` starts a comment line.
guard let allowData = FileManager.default.contents(atPath: root + "/" + allowFile) else {
    fail("can't read \(allowFile)")
}
var problems: [String] = []
var notes: [String] = []
var ceilings: [String: (ceiling: Int, line: Int)] = [:]
for (offset, raw) in String(decoding: allowData, as: UTF8.self).components(separatedBy: "\n")
    .enumerated()
{
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let at = "\(allowFile):\(offset + 1):"
    let parts = line.components(separatedBy: " | ")
    let head = parts[0].split(separator: " ")
    guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty,
        head.count == 2, let ceiling = Int(head[1])
    else {
        problems.append("\(at) expected `<path> <ceiling> | <reason>`")
        continue
    }
    let path = String(head[0])
    if let first = ceilings[path] {
        problems.append("\(at) repeats line \(first.line)")
        continue
    }
    ceilings[path] = (ceiling, offset + 1)
    guard let length = lengths[path] else {
        problems.append("\(at) \(path) doesn't exist, delete the entry")
        continue
    }
    if length <= limit {
        problems.append("\(at) \(path) is \(length) lines, at or under \(limit): delete the entry")
    } else if length > ceiling {
        problems.append(
            "\(at) \(path) is \(length) lines, over its ceiling of \(ceiling): split it or cut it")
    } else if length < ceiling {
        notes.append("\(at) \(path) is \(length) lines: lower its ceiling to \(length)")
    }
}

for (path, length) in lengths.sorted(by: { $0.key < $1.key })
where length > limit && ceilings[path] == nil {
    problems.append("\(path): \(length) lines, over \(limit): split it along a seam it has")
}

for note in notes { print(note) }
if !problems.isEmpty {
    for problem in problems { print(problem) }
    exit(1)
}
print(
    "\(lengths.count) files, none over \(limit) lines outside the allowlist"
        + " (\(ceilings.count) entries)")
