// Finds facts defined twice and code copied three times under Sources (AGENTS.md principles 1 and
// 3; what counts is in ADR 0024). Tests may repeat literals, so only Sources is read.
//
//   swift scripts/dupes.swift [--root <dir>]
//
// <dir> (default: the current directory) holds Sources/ and scripts/dupes-allow.txt. Exits 1 on any
// finding outside the allowlist, on an allowlist entry that matches nothing, or on a malformed one.
import Foundation

// A literal shorter than this, once interpolations and format specifiers are taken out, is too
// generic to be a fact ("Play", "flac" and atom IDs are four).
let minimumLiteralCharacters = 4
// A block is this many lines that aren't only punctuation, compared with identifiers and literals
// normalized, so a copy with renamed variables still matches.
let blockLines = 8
// A block's third copy fails; a second copy this long is printed as advisory.
let failingCopies = 3
let advisoryBlockLines = 20
// Below this many distinct normalized lines a window is a run of near-identical lines (a switch
// mapping cases, a list of properties), which is the code's shape, not a copy.
let minimumDistinctLines = 6

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
        fail("unknown argument \(flag); usage: swift scripts/dupes.swift [--root <dir>]")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dupes: \(message)\n".utf8))
    exit(2)
}

// MARK: - Lexing

struct Literal {
    var text: String
    var line: Int
    // The innermost call the literal is an argument of, such as `fatalError`.
    var call: String?
}

struct LexedFile {
    var literals: [Literal] = []
    // Normalized tokens of each source line, indexed from 0 for line 1.
    var lines: [[String]] = []
}

let keywords: Set<String> = [
    "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do",
    "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard",
    "if",
    "import", "in", "init", "inout", "internal", "is", "let", "nil", "open", "package", "private",
    "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "static", "struct",
    "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where",
    "while", "actor", "some", "any", "weak", "unowned", "lazy", "final", "override", "mutating",
    "nonisolated", "convenience", "deinit", "get", "set", "willSet", "didSet",
    // C
    "const", "int", "void", "unsigned", "sizeof", "typedef", "uint32_t", "float", "double", "char",
]

let quote = UInt8(ascii: "\"")
let backslash = UInt8(ascii: "\\")
let hash = UInt8(ascii: "#")
let slash = UInt8(ascii: "/")
let star = UInt8(ascii: "*")
let newline = UInt8(ascii: "\n")
let openParen = UInt8(ascii: "(")
let closeParen = UInt8(ascii: ")")
let apostrophe = UInt8(ascii: "'")

func isIdentifierByte(_ byte: UInt8) -> Bool {
    (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57)
        || byte == 95 || byte == 36 || byte >= 0x80
}

final class Lexer {
    let bytes: [UInt8]
    let isC: Bool
    var position = 0
    var line = 0
    var file = LexedFile()
    // The word before each open parenthesis, innermost last, and the last token if it was a word.
    var calls: [String?] = []
    var lastWord: String?

    init(bytes: [UInt8], isC: Bool) {
        self.bytes = bytes
        self.isC = isC
        file.lines = [[]]
    }

    func peek(_ offset: Int = 0) -> UInt8? {
        position + offset < bytes.count ? bytes[position + offset] : nil
    }

    func emit(_ token: String, word: String? = nil) {
        file.lines[line].append(token)
        lastWord = word
    }

    func advanceLine() {
        line += 1
        file.lines.append([])
    }

    // Lexes code until the end of the file, or until the `)` closing an interpolation.
    func code(inInterpolation: Bool) {
        var depth = 0
        while let byte = peek() {
            if byte == newline {
                advanceLine()
                position += 1
            } else if byte == slash && peek(1) == slash {
                while let next = peek(), next != newline { position += 1 }
            } else if byte == slash && peek(1) == star {
                blockComment()
            } else if isC && byte == hash && file.lines[line].isEmpty {
                // A preprocessor line: its include names aren't facts, and its macros aren't code.
                while let next = peek(), next != newline { position += 1 }
            } else if isC && byte == apostrophe {
                skipCharacterLiteral()
                emit("S")
            } else if byte == quote || (!isC && byte == hash && rawStringHashes() != nil) {
                string()
                emit("S")
            } else if isIdentifierByte(byte) {
                let start = position
                while let next = peek(), isIdentifierByte(next) { position += 1 }
                let word = String(decoding: bytes[start..<position], as: UTF8.self)
                if let first = word.utf8.first, first >= 48 && first <= 57 {
                    emit("N")
                } else {
                    emit(keywords.contains(word) ? word : "I", word: word)
                }
            } else if byte == 32 || byte == 9 || byte == 13 {
                position += 1
            } else {
                if byte == openParen {
                    depth += 1
                    calls.append(lastWord)
                }
                if byte == closeParen {
                    if depth == 0 && inInterpolation {
                        position += 1
                        return
                    }
                    depth -= 1
                    _ = calls.popLast()
                }
                emit(String(UnicodeScalar(byte)))
                position += 1
            }
        }
    }

    func blockComment() {
        var depth = 0
        while let byte = peek() {
            if byte == slash && peek(1) == star {
                depth += 1
                position += 2
            } else if byte == star && peek(1) == slash {
                depth -= 1
                position += 2
                if depth == 0 { return }
            } else {
                if byte == newline { advanceLine() }
                position += 1
            }
        }
    }

    func skipCharacterLiteral() {
        position += 1
        while let byte = peek(), byte != apostrophe {
            position += byte == backslash ? 2 : 1
        }
        position += 1
    }

    // The number of `#`s before a raw string's opening quote, or nil if this `#` starts something
    // else (`#if`, `#available`).
    func rawStringHashes() -> Int? {
        var count = 0
        while peek(count) == hash { count += 1 }
        return peek(count) == quote ? count : nil
    }

    // Reads a string literal starting at the current position, recording its text with each
    // interpolation as `\(…)` and lexing the interpolated code, which may hold literals of its own.
    func string() {
        let hashes = isC ? 0 : rawStringHashes()!
        position += hashes
        let startLine = line + 1
        let call = calls.last ?? nil
        let multiline = peek(0) == quote && peek(1) == quote && peek(2) == quote
        let delimiter = multiline ? 3 : 1
        position += delimiter
        var text: [UInt8] = []
        while let byte = peek() {
            if byte == quote && closes(delimiter: delimiter, hashes: hashes) {
                position += delimiter + hashes
                break
            }
            if byte == backslash && (0..<hashes).allSatisfy({ peek(1 + $0) == hash }) {
                if !isC && peek(1 + hashes) == openParen {
                    position += 2 + hashes
                    text.append(contentsOf: Array("\\(…)".utf8))
                    code(inInterpolation: true)
                    continue
                }
                text.append(contentsOf: bytes[position..<min(position + 2 + hashes, bytes.count)])
                position += 2 + hashes
                continue
            }
            if byte == newline {
                if !multiline { break }
                advanceLine()
            }
            text.append(byte)
            position += 1
        }
        file.literals.append(
            Literal(text: String(decoding: text, as: UTF8.self), line: startLine, call: call))
    }

    func closes(delimiter: Int, hashes: Int) -> Bool {
        for offset in 0..<delimiter where peek(offset) != quote { return false }
        for offset in 0..<hashes where peek(delimiter + offset) != hash { return false }
        return true
    }
}

// MARK: - Reading the tree

let sources = URL(fileURLWithPath: root).appendingPathComponent("Sources")
guard let walker = FileManager.default.enumerator(atPath: sources.path) else {
    fail("no Sources directory under \(root)")
}
var paths: [String] = []
while let relative = walker.nextObject() as? String {
    if relative.hasSuffix(".swift") || relative.hasSuffix(".c") || relative.hasSuffix(".h") {
        paths.append("Sources/" + relative)
    }
}
paths.sort()
if paths.isEmpty { fail("no source files under \(sources.path)") }

var lexed: [LexedFile] = []
for path in paths {
    guard let data = FileManager.default.contents(atPath: root + "/" + path) else {
        fail("can't read \(path)")
    }
    let lexer = Lexer(bytes: [UInt8](data), isC: !path.hasSuffix(".swift"))
    lexer.code(inInterpolation: false)
    lexed.append(lexer.file)
}

// MARK: - Allowlist

// One entry per line, `<kind> <key> | <reason>`; `#` starts a comment line. The kinds:
//   literal "<text as written>"  -- that literal may appear in several files
//   block <file> <file>…         -- a repeated block whose copies are in exactly these files
//   oracle <directory>           -- a Tools module that re-types format facts on purpose, as a
//                                   test does, so its literals aren't compared with anything
let allowFile = "scripts/dupes-allow.txt"
guard let allowData = FileManager.default.contents(atPath: root + "/" + allowFile) else {
    fail("can't read \(allowFile)")
}
var problems: [String] = []
var allowed: [String: Int] = [:]  // key -> line number
var oracles: [String: Int] = [:]  // directory with a trailing slash -> line number
for (offset, raw) in String(decoding: allowData, as: UTF8.self).components(separatedBy: "\n")
    .enumerated()
{
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let number = offset + 1
    // The separator is the last ` | `, so a literal may hold one.
    guard let bar = line.range(of: " | ", options: .backwards),
        !line[bar.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
    else {
        problems.append("\(allowFile):\(number): entry has no ` | <reason>`")
        continue
    }
    let key = String(line[..<bar.lowerBound]).trimmingCharacters(in: .whitespaces)
    if key.hasPrefix("oracle ") {
        oracles[String(key.dropFirst("oracle ".count)) + "/"] = number
    } else if key.hasPrefix("literal \"") && key.hasSuffix("\"") || key.hasPrefix("block ") {
        if let first = allowed[key] {
            problems.append("\(allowFile):\(number): repeats line \(first)")
        }
        allowed[key] = number
    } else {
        problems.append(
            "\(allowFile):\(number): expected `literal \"…\"`, `block <files>` or `oracle <dir>`")
    }
}

func oracle(_ path: String) -> String? { oracles.keys.first { path.hasPrefix($0) } }

// MARK: - Findings

struct Finding {
    // What an allowlist entry names: `literal "<text>"` or `block <file> <file>…`.
    var key: String
    var report: String
    var fails: Bool
}

var findings: [Finding] = []
var usedOracles: Set<String> = []

// Interpolations and printf specifiers are someone else's facts; what's left is this literal's.
// An escape is one character, and `\n` or `\t` is white space.
let notOwn = try! NSRegularExpression(
    pattern:
        #"\\\(…\)|%[-+ #0']*[0-9*]*(\.[0-9*]+)?(hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGcCsSpaA%]"#)
let whiteEscape = try! NSRegularExpression(pattern: ##"\\#*[nrt]"##)
let otherEscape = try! NSRegularExpression(pattern: ##"\\#*(u\{[0-9a-fA-F]+\}|.)"##)

func ownCharacters(_ text: String) -> Int {
    var own = text
    for (pattern, template) in [(notOwn, ""), (whiteEscape, " "), (otherEscape, "x")] {
        own = pattern.stringByReplacingMatches(
            in: own, range: NSRange(own.startIndex..., in: own), withTemplate: template)
    }
    return own.trimmingCharacters(in: .whitespacesAndNewlines).count
}

// A message for a programmer error at one place: never shown in the UI, never compared.
let diagnostics: Set<String> = [
    "fatalError", "precondition", "preconditionFailure", "assert", "assertionFailure",
]

// The literal as written, on one line.
func spelling(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
}

var literalSites: [String: [(file: Int, line: Int)]] = [:]
for (index, file) in lexed.enumerated() {
    for literal in file.literals
    where ownCharacters(literal.text) >= minimumLiteralCharacters
        && !diagnostics.contains(literal.call ?? "")
    {
        literalSites[literal.text, default: []].append((index, literal.line))
    }
}
for (text, allSites) in literalSites {
    guard Set(allSites.map(\.file)).count > 1 else { continue }
    let sites = allSites.filter { oracle(paths[$0.file]) == nil }
    for site in allSites { if let dir = oracle(paths[site.file]) { usedOracles.insert(dir) } }
    let files = Set(sites.map(\.file))
    guard files.count > 1 else { continue }
    let shown = text.count > 120 ? String(text.prefix(117)) + "..." : text
    let lines = sites.map { "  \(paths[$0.file]):\($0.line)" }.joined(separator: "\n")
    findings.append(
        Finding(
            key: "literal \(spelling(text))",
            report: "literal \(spelling(shown)) in \(files.count) files:\n\(lines)", fails: true))
}

// Code blocks: windows of significant lines, keyed by their normalized tokens.
let punctuationOnly: Set<String> = ["{", "}", "(", ")", "[", "]", ",", ";"]
struct Site: Hashable {
    var file: Int
    var index: Int  // into that file's significant lines
}
var significant: [[(line: Int, text: String)]] = []
for file in lexed {
    var kept: [(line: Int, text: String)] = []
    for (number, tokens) in file.lines.enumerated() {
        guard tokens.contains(where: { !punctuationOnly.contains($0) }), tokens.first != "import"
        else { continue }
        kept.append((number + 1, tokens.joined(separator: " ")))
    }
    significant.append(kept)
}

func window(_ site: Site) -> String? {
    let lines = significant[site.file]
    guard site.index >= 0, site.index + blockLines <= lines.count else { return nil }
    return lines[site.index..<site.index + blockLines].map(\.text).joined(separator: "\n")
}

var windowSites: [String: [Site]] = [:]
for (file, lines) in significant.enumerated() where lines.count >= blockLines {
    for index in 0...(lines.count - blockLines) {
        let slice = lines[index..<index + blockLines]
        guard Set(slice.map(\.text)).count >= minimumDistinctLines else { continue }
        windowSites[slice.map(\.text).joined(separator: "\n"), default: []].append(
            Site(file: file, index: index))
    }
}

// Copies of one block in the same file can't overlap; keep the first of each run.
func separate(_ sites: [Site]) -> [Site] {
    var kept: [Site] = []
    for site in sites.sorted(by: { ($0.file, $0.index) < ($1.file, $1.index) }) {
        if let last = kept.last, last.file == site.file, site.index < last.index + blockLines {
            continue
        }
        kept.append(site)
    }
    return kept
}

for rawSites in windowSites.values {
    let sites = separate(rawSites)
    guard sites.count >= 2 else { continue }
    // Report each block once, from its first window: skip a window whose copies all continue one
    // line earlier as the same window.
    let earlier = sites.map { Site(file: $0.file, index: $0.index - 1) }
    if let previous = window(earlier[0]), earlier.allSatisfy({ window($0) == previous }),
        separate(windowSites[previous] ?? []).count == sites.count
    {
        continue
    }
    var extra = 0
    while true {
        let next = sites.map { Site(file: $0.file, index: $0.index + extra + 1) }
        guard let first = window(next[0]), next.allSatisfy({ window($0) == first }) else { break }
        extra += 1
    }
    let spans = sites.map { site -> (file: Int, start: Int, end: Int) in
        let lines = significant[site.file]
        return (site.file, lines[site.index].line, lines[site.index + blockLines - 1 + extra].line)
    }
    let length = spans[0].end - spans[0].start + 1
    let fails = sites.count >= failingCopies
    guard fails || length >= advisoryBlockLines else { continue }
    let files = Set(spans.map { paths[$0.file] }).sorted()
    let locations = spans.map { "  \(paths[$0.file]):\($0.start)-\($0.end)" }
        .joined(separator: "\n")
    findings.append(
        Finding(
            key: "block " + files.joined(separator: " "),
            report: "\(fails ? "" : "advisory: ")block of \(length) lines, \(sites.count) copies:\n"
                + locations, fails: fails))
}

// MARK: - Report

var used: Set<String> = []
var reported: [Finding] = []
for finding in findings {
    if allowed[finding.key] != nil {
        used.insert(finding.key)
    } else {
        reported.append(finding)
    }
}
for (key, number) in allowed where !used.contains(key) {
    problems.append("\(allowFile):\(number): matches nothing, delete it: \(key)")
}
for (directory, number) in oracles where !usedOracles.contains(directory) {
    problems.append("\(allowFile):\(number): matches nothing, delete it: oracle \(directory)")
}

reported.sort { ($0.fails ? 0 : 1, $0.report) < ($1.fails ? 0 : 1, $1.report) }
for finding in reported { print(finding.report) }
problems.sort()
for problem in problems { print(problem) }
let failing = reported.filter(\.fails).count
if failing == 0 && problems.isEmpty {
    print(
        "\(paths.count) files, nothing outside the allowlist (\(allowed.count + oracles.count)"
            + " entries, \(reported.count) advisory)")
} else {
    FileHandle.standardError.write(
        Data("dupes: \(failing) findings, \(problems.count) allowlist problems\n".utf8))
    exit(1)
}
