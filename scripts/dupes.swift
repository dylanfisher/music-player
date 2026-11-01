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
    // A message for a programmer error at one place, never shown and never compared.
    var isDiagnostic: Bool
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
let comma = UInt8(ascii: ",")
let opening: Set<UInt8> = [openParen, UInt8(ascii: "["), UInt8(ascii: "{")]
let closing: Set<UInt8> = [closeParen, UInt8(ascii: "]"), UInt8(ascii: "}")]
let messageOnly: Set<String> = ["fatalError", "preconditionFailure", "assertionFailure"]
let conditionThenMessage: Set<String> = ["precondition", "assert"]

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
    // Each open bracket, innermost last: the word before a parenthesis, and the top-level commas
    // seen inside it so far. The last token if it was a word.
    var calls: [(word: String?, commas: Int)] = []
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
                // A backslash at a line's end continues it.
                while let next = peek(), next != newline {
                    if next == backslash && peek(1) == newline {
                        advanceLine()
                        position += 1
                    }
                    position += 1
                }
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
                if byte == openParen { depth += 1 }
                if byte == closeParen {
                    if depth == 0 && inInterpolation {
                        position += 1
                        return
                    }
                    depth -= 1
                }
                if opening.contains(byte) { calls.append((byte == openParen ? lastWord : nil, 0)) }
                if closing.contains(byte) { _ = calls.popLast() }
                if byte == comma, !calls.isEmpty { calls[calls.count - 1].commas += 1 }
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
        let isDiagnostic = diagnosticMessage()
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
                // A backslash at a line's end joins the next line to this one.
                if peek(1 + hashes) == newline { advanceLine() }
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
        var literal = String(decoding: text, as: UTF8.self)
        if multiline { literal = withoutIndentation(literal) }
        file.literals.append(Literal(text: literal, line: startLine, isDiagnostic: isDiagnostic))
    }

    // Whether a string starting here is the message of `fatalError` or `preconditionFailure`, or
    // the message argument of `precondition` or `assert`, the one after the condition, labelled
    // or not. A literal in the condition, or in `file:`, still counts.
    func diagnosticMessage() -> Bool {
        guard let call = calls.last, let word = call.word else { return false }
        if messageOnly.contains(word) { return true }
        return conditionThenMessage.contains(word) && call.commas == 1
    }

    // A multi-line string's text as Swift reads it: from the line after the opening delimiter to
    // the line before the closing one, with the closing delimiter's indentation taken off each.
    func withoutIndentation(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        let indentation = lines.removeLast()
        lines.removeFirst()
        return lines.map {
            $0.hasPrefix(indentation) ? String($0.dropFirst(indentation.count)) : $0
        }
        .joined(separator: "\n")
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

// One entry per line, `<kind> <key> | <scope> | <reason>`; `#` starts a comment line. The kinds:
//   literal "<as written>" | files <file>…    -- that literal in exactly these files
//   block <fingerprint> x<copies> | files <file>…   -- that block, that many times, in exactly
//                                                     these files
//   oracle <directory> | checks <directory>…  -- a Tools module that re-types the checked
//                                                modules' format facts on purpose, as a test
//                                                does, so a literal it shares with them is hidden
// Each finding prints its key, everything before the reason.
let allowFile = "scripts/dupes-allow.txt"
guard let allowData = FileManager.default.contents(atPath: root + "/" + allowFile) else {
    fail("can't read \(allowFile)")
}
var problems: [String] = []
var allowed: [String: Int] = [:]  // key -> line number
var oracles: [String: (checks: [String], line: Int)] = [:]  // directories end in a slash
for (offset, raw) in String(decoding: allowData, as: UTF8.self).components(separatedBy: "\n")
    .enumerated()
{
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let number = offset + 1
    let at = "\(allowFile):\(number):"
    // The reason follows the last ` | `, the scope the one before, so a literal may hold one.
    guard !line.hasSuffix("|"), let bar = line.range(of: " | ", options: .backwards),
        !line[bar.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
    else {
        problems.append("\(at) entry has no ` | <reason>`")
        continue
    }
    let key = String(line[..<bar.lowerBound]).trimmingCharacters(in: .whitespaces)
    guard let scopeBar = key.range(of: " | ", options: .backwards) else {
        problems.append("\(at) entry has no ` | files …` or ` | checks …`")
        continue
    }
    let head = String(key[..<scopeBar.lowerBound])
    let scope = key[scopeBar.upperBound...].split(separator: " ").map(String.init)
    if head.hasPrefix("oracle "), head.split(separator: " ").count == 2, scope.first == "checks",
        scope.count > 1
    {
        let directory = String(head.dropFirst("oracle ".count)) + "/"
        if let first = oracles[directory] { problems.append("\(at) repeats line \(first.line)") }
        oracles[directory] = (scope.dropFirst().map { $0 + "/" }, number)
    } else if head.hasPrefix("literal \"") && head.hasSuffix("\"") && head.count > 9
        || head.range(of: #"^block [0-9a-f]{8} x[0-9]+$"#, options: .regularExpression) != nil,
        scope.first == "files", scope.count > 1
    {
        if let first = allowed[key] { problems.append("\(at) repeats line \(first)") }
        allowed[key] = number
    } else {
        problems.append(
            "\(at) expected `literal \"…\" | files …`, `block <fingerprint> x<copies> | files …`"
                + " or `oracle <dir> | checks <dir>…`")
    }
}

// The oracle `path` is in, and the directories it checks.
func oracle(_ path: String) -> (directory: String, checks: [String])? {
    guard let entry = oracles.first(where: { path.hasPrefix($0.key) }) else { return nil }
    return (entry.key, entry.value.checks)
}

// MARK: - Findings

struct Finding {
    // What an allowlist entry names, before its reason.
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

// The literal as written, on one line.
func spelling(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
}

var literalSites: [String: [(file: Int, line: Int)]] = [:]
for (index, file) in lexed.enumerated() {
    for literal in file.literals
    where ownCharacters(literal.text) >= minimumLiteralCharacters
        && !literal.isDiagnostic
    {
        literalSites[literal.text, default: []].append((index, literal.line))
    }
}
for (text, allSites) in literalSites {
    guard Set(allSites.map(\.file)).count > 1 else { continue }
    // An oracle's copy is hidden only when a module it checks spells the literal too.
    var hiders: Set<String> = []
    let sites = allSites.filter { site in
        guard let oracle = oracle(paths[site.file]),
            allSites.contains(where: { other in
                oracle.checks.contains { paths[other.file].hasPrefix($0) }
            })
        else { return true }
        hiders.insert(oracle.directory)
        return false
    }
    let files = Set(sites.map(\.file))
    guard files.count > 1 else {
        usedOracles.formUnion(hiders)
        continue
    }
    let shown = text.count > 120 ? String(text.prefix(117)) + "..." : text
    let lines = sites.map { "  \(paths[$0.file]):\($0.line)" }.joined(separator: "\n")
    let key =
        "literal \(spelling(text)) | files "
        + Set(sites.map { paths[$0.file] }).sorted()
        .joined(separator: " ")
    findings.append(
        Finding(
            key: key,
            report: "literal \(spelling(shown)) in \(files.count) files:\n\(lines)\n  key: \(key)",
            fails: true))
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

// FNV-1a of a block's first window, as 8 hex digits: the same on every run, unlike `Hasher`.
func fingerprint(_ text: String) -> String {
    var hash: UInt32 = 2_166_136_261
    for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
    return String(format: "%08x", hash)
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
    let key =
        "block \(fingerprint(window(sites[0])!)) x\(sites.count) | files "
        + files.joined(separator: " ")
    findings.append(
        Finding(
            key: key,
            report: "\(fails ? "" : "advisory: ")block of \(length) lines, \(sites.count) copies:\n"
                + locations + "\n  key: \(key)", fails: fails))
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
for (directory, entry) in oracles where !usedOracles.contains(directory) {
    problems.append(
        "\(allowFile):\(entry.line): hides nothing that needs it, delete it: oracle \(directory)")
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
