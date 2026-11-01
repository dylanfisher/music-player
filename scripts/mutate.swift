// Lists and applies source mutants for scripts/mutate (ADR 0027). Foundation only.
//
//   swift scripts/mutate.swift list <file> [<first line>-<last line>]
//   swift scripts/mutate.swift apply <file> <id>
//
// `list` prints one mutant per line: `<id>\t<line>\t<what changed>`. `apply` rewrites the file
// with that mutant. Mutants are made only in code, never in comments or strings: a comparison
// flipped at its boundary (`<` and `<=`, `>` and `>=`) or negated (`==` and `!=`), `&&` and `||`
// swapped, a statement on its own line dropped, and an integer literal changed by one.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mutate: \(message)\n".utf8))
    exit(2)
}

struct Mutant {
    var range: Range<Int>
    var replacement: [UInt8]
    var line: Int
    var summary: String
}

/// Whether each byte is code, as opposed to a comment or a string literal's contents.
func codeMask(_ bytes: [UInt8]) -> [Bool] {
    var mask = [Bool](repeating: false, count: bytes.count)
    var index = 0
    func at(_ offset: Int) -> UInt8? { offset < bytes.count ? bytes[offset] : nil }
    let quote = UInt8(ascii: "\""), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
    let pound = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\"), newline = UInt8(ascii: "\n")
    while index < bytes.count {
        let byte = bytes[index]
        if byte == slash, at(index + 1) == slash {
            while index < bytes.count, bytes[index] != newline { index += 1 }
            continue
        }
        if byte == slash, at(index + 1) == star {
            var depth = 1
            index += 2
            while index < bytes.count, depth > 0 {
                if bytes[index] == slash, at(index + 1) == star {
                    depth += 1
                    index += 2
                } else if bytes[index] == star, at(index + 1) == slash {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
            continue
        }
        // A string: its pounds, then one quote or three. It ends at the same quotes and pounds.
        var pounds = 0
        while at(index + pounds) == pound { pounds += 1 }
        if at(index + pounds) == quote {
            let triple = at(index + pounds + 1) == quote && at(index + pounds + 2) == quote
            let quotes = triple ? 3 : 1
            index += pounds + quotes
            let closing = [UInt8](repeating: quote, count: quotes)
                + [UInt8](repeating: pound, count: pounds)
            while index < bytes.count {
                if pounds == 0, bytes[index] == backslash {
                    index += 2
                    continue
                }
                if Array(bytes[index..<min(index + closing.count, bytes.count)]) == closing {
                    index += closing.count
                    break
                }
                index += 1
            }
            continue
        }
        mask[index] = true
        index += 1
    }
    return mask
}

func isIdentifier(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
        || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_")
}

/// Words that start a line which isn't a statement to drop: declarations, control flow, and
/// what a dropped line would leave uncompilable or meaningless.
let keptStarts: Set<String> = [
    "let", "var", "func", "return", "throw", "guard", "if", "else", "for", "while", "switch",
    "case", "default", "defer", "do", "catch", "break", "continue", "struct", "class", "enum",
    "extension", "init", "private", "public", "package", "fileprivate", "static", "import",
    "protocol", "typealias", "precondition", "preconditionFailure", "fatalError", "assert",
    "repeat", "override", "final", "nonisolated", "mutating", "weak", "lazy",
]

func mutants(_ bytes: [UInt8]) -> [Mutant] {
    let mask = codeMask(bytes)
    var lineStarts = [0]
    for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
        lineStarts.append(index + 1)
    }
    func lineNumber(_ offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }
    func code(_ range: Range<Int>) -> Bool { range.allSatisfy { $0 < mask.count && mask[$0] } }
    var found: [Mutant] = []

    // Operators, with the spaces the formatter puts around a binary operator, which generics,
    // ranges and shifts don't have.
    let swaps: [(String, String, String)] = [
        (" < ", " <= ", "boundary"), (" <= ", " < ", "boundary"), (" > ", " >= ", "boundary"),
        (" >= ", " > ", "boundary"), (" == ", " != ", "negated"), (" != ", " == ", "negated"),
        (" && ", " || ", "swapped"), (" || ", " && ", "swapped"),
    ]
    for (from, to, kind) in swaps {
        let pattern = Array(from.utf8)
        var index = 0
        while index + pattern.count <= bytes.count {
            let range = index..<index + pattern.count
            if Array(bytes[range]) == pattern, code(range) {
                let line = lineNumber(index)
                found.append(
                    Mutant(
                        range: range, replacement: Array(to.utf8), line: line,
                        summary: "\(kind) \(from.trimmingCharacters(in: .whitespaces)) to"
                            + " \(to.trimmingCharacters(in: .whitespaces))"))
            }
            index += 1
        }
    }

    // Integer literals, by one.
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte), mask[index],
            index == 0
                || (!isIdentifier(bytes[index - 1])
                    && ![UInt8(ascii: "."), UInt8(ascii: "$")].contains(bytes[index - 1]))
        else {
            index += 1
            continue
        }
        var end = index
        while end < bytes.count, isIdentifier(bytes[end]) { end += 1 }
        let text = String(decoding: bytes[index..<end], as: UTF8.self)
        let followedByFraction =
            end + 1 < bytes.count && bytes[end] == UInt8(ascii: ".")
            && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end + 1])
        let line = lineNumber(index)
        let lineText = String(
            decoding: bytes[lineStarts[line - 1]..<(line < lineStarts.count ? lineStarts[line] : bytes.count)],
            as: UTF8.self)
        if let value = Int(text.replacingOccurrences(of: "_", with: "")), !followedByFraction,
            !lineText.contains("available(")
        {
            for changed in [value + 1, value - 1] where changed >= 0 {
                found.append(
                    Mutant(
                        range: index..<end, replacement: Array(String(changed).utf8), line: line,
                        summary: "constant \(value) to \(changed)"))
            }
        }
        index = end
    }

    // Statements on their own line.
    let texts = (0..<lineStarts.count).map { line -> String in
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : bytes.count
        return String(
            decoding: (start..<end).map { mask[$0] ? bytes[$0] : UInt8(ascii: " ") }, as: UTF8.self
        ).trimmingCharacters(in: .whitespaces)
    }
    for line in texts.indices {
        let text = texts[line]
        guard let first = text.split(whereSeparator: { !isIdentifier(UInt8($0.asciiValue ?? 0)) }).first,
            let lead = text.first, lead.isLetter || lead == "_",
            !keptStarts.contains(String(first)),
            text.contains("(") || text.contains(" = ") || text.contains(" += ")
                || text.contains(" -= "),
            text.filter({ $0 == "(" }).count == text.filter({ $0 == ")" }).count,
            text.filter({ $0 == "[" }).count == text.filter({ $0 == "]" }).count,
            !text.contains("{"), !text.contains("}")
        else { continue }
        let previous = texts[..<line].last { !$0.isEmpty } ?? ""
        let next = texts[(line + 1)...].first { !$0.isEmpty } ?? ""
        let continues =
            ["(", ",", "=", "&&", "||", "+", "-", "?", ":", "in"].contains { previous.hasSuffix($0) }
            || [".", ")", "]", "&&", "||", "+", "?", ":"].contains { next.hasPrefix($0) }
            || ["=", "&&", "||", "+", "-", "?", "."].contains { text.hasSuffix($0) }
        guard !continues else { continue }
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : bytes.count
        found.append(
            Mutant(range: start..<end, replacement: [], line: line + 1, summary: "dropped \(text)"))
    }
    return found.sorted { ($0.line, $0.range.lowerBound, $0.summary) < ($1.line, $1.range.lowerBound, $1.summary) }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { fail("usage: list <file> [<a>-<b>] | apply <file> <id>") }
let command = arguments.removeFirst()
let path = arguments.removeFirst()
guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
let bytes = [UInt8](data)

switch command {
case "list":
    var lines: ClosedRange<Int>?
    if let range = arguments.first {
        let parts = range.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[0] <= parts[1], arguments.count == 1 else {
            fail("the line range is <first>-<last>, not \(arguments.joined(separator: " "))")
        }
        lines = parts[0]...parts[1]
    }
    // Ids count every mutant in the file, so `apply` finds one without the range.
    for (id, mutant) in mutants(bytes).enumerated() where lines?.contains(mutant.line) ?? true {
        print("\(id)\t\(mutant.line)\t\(mutant.summary)")
    }
case "apply":
    guard arguments.count == 1, let id = Int(arguments[0]) else { fail("apply needs a mutant id") }
    let all = mutants(bytes)
    guard all.indices.contains(id) else { fail("\(path) has no mutant \(id)") }
    var changed = bytes
    changed.replaceSubrange(all[id].range, with: all[id].replacement)
    do {
        try Data(changed).write(to: URL(fileURLWithPath: path))
    } catch {
        fail("can't write \(path): \(error)")
    }
default:
    fail("the command is list or apply, not \(command)")
}
