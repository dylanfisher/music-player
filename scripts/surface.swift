// Finds `public` and `package` declarations under Sources that nothing outside their module uses,
// so each module exposes only what other modules call (ADR 0030).
//
//   swift scripts/surface.swift [--root <dir>]
//
// <dir> (default: the current directory) holds Sources/ and scripts/surface-allow.txt. Exits 1
// on any finding outside the allowlist, on an allowlist entry that matches nothing, or on a
// malformed one.
//
// It matches names, not types: a declaration counts as used when its name appears in a module
// that imports its module, directly or through another module, or in another public
// declaration's signature in its own module (a parameter type, a default argument, an enum
// case's payload). Two members that share a name hide each other, so it misses some unused
// declarations. Tests don't count: they reach internals through `@testable import`. An access
// level on a member of an internal type is a finding too, as it changes nothing.
import Foundation

// Members a public type has to make public to conform to a standard protocol, which the compiler
// calls rather than another module.
let witnesses: Set<String> = [
    "description", "debugDescription", "hash", "encode", "id", "errorDescription", "rawValue",
    "allCases", "makeIterator", "next",
]
// The labels of initializers a standard protocol requires: `init(rawValue:)`, `init(from:)` and
// each `ExpressibleBy…Literal` one.
let witnessLabels: Set<String> = ["rawValue", "Decoder"]
let accessLevels: Set<String> = ["public", "package", "open"]
let modifiers: Set<String> = [
    "static", "class", "final", "override", "required", "convenience", "mutating", "nonmutating",
    "nonisolated", "lazy", "weak", "unowned", "indirect", "dynamic", "private", "fileprivate",
    "internal", "(", "set", ")",
]
let typeKeywords: Set<String> = ["struct", "class", "enum", "protocol", "actor", "extension"]
let declarationKeywords: Set<String> =
    typeKeywords.union(["func", "var", "let", "typealias", "init", "subscript"])

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
        fail("unknown argument \(flag); usage: swift scripts/surface.swift [--root <dir>]")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("surface: \(message)\n".utf8))
    exit(2)
}

// MARK: - Lexing

struct Token {
    var text: String
    var line: Int
}

let quote = UInt8(ascii: "\"")
let backslash = UInt8(ascii: "\\")
let hash = UInt8(ascii: "#")
let slash = UInt8(ascii: "/")
let star = UInt8(ascii: "*")
let newline = UInt8(ascii: "\n")
let openParen = UInt8(ascii: "(")
let closeParen = UInt8(ascii: ")")
let backtick = UInt8(ascii: "`")

func isIdentifierByte(_ byte: UInt8) -> Bool {
    (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57)
        || byte == 95 || byte == 36 || byte >= 0x80
}

// Code as words, punctuation and line ends. Comments and string text are dropped; the code in a
// string's interpolations is kept.
final class Lexer {
    let bytes: [UInt8]
    var position = 0
    var line = 1
    var tokens: [Token] = []

    init(bytes: [UInt8]) { self.bytes = bytes }

    func peek(_ offset: Int = 0) -> UInt8? {
        position + offset < bytes.count ? bytes[position + offset] : nil
    }

    func emit(_ text: String) { tokens.append(Token(text: text, line: line)) }

    func code(inInterpolation: Bool) {
        var depth = 0
        while let byte = peek() {
            if byte == newline {
                emit("\n")
                line += 1
                position += 1
            } else if byte == slash && peek(1) == slash {
                while let next = peek(), next != newline { position += 1 }
            } else if byte == slash && peek(1) == star {
                blockComment()
            } else if byte == quote || (byte == hash && rawStringHashes() != nil) {
                string()
            } else if isIdentifierByte(byte) || byte == backtick {
                if byte == backtick { position += 1 }
                let start = position
                while let next = peek(), isIdentifierByte(next) { position += 1 }
                emit(String(decoding: bytes[start..<position], as: UTF8.self))
                if peek() == backtick { position += 1 }
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
                if byte == newline { line += 1 }
                position += 1
            }
        }
    }

    // The number of `#`s before a raw string's opening quote, or nil if this `#` starts something
    // else (`#if`, `#available`).
    func rawStringHashes() -> Int? {
        var count = 0
        while peek(count) == hash { count += 1 }
        return peek(count) == quote ? count : nil
    }

    func string() {
        let hashes = rawStringHashes()!
        position += hashes
        let multiline = peek(0) == quote && peek(1) == quote && peek(2) == quote
        let delimiter = multiline ? 3 : 1
        position += delimiter
        while let byte = peek() {
            if byte == quote && closes(delimiter: delimiter, hashes: hashes) {
                position += delimiter + hashes
                return
            }
            if byte == backslash && (0..<hashes).allSatisfy({ peek(1 + $0) == hash }) {
                if peek(1 + hashes) == openParen {
                    position += 2 + hashes
                    code(inInterpolation: true)
                    continue
                }
                if peek(1 + hashes) == newline { line += 1 }
                position += 2 + hashes
                continue
            }
            if byte == newline {
                if !multiline { return }
                line += 1
            }
            position += 1
        }
    }

    func closes(delimiter: Int, hashes: Int) -> Bool {
        for offset in 0..<delimiter where peek(offset) != quote { return false }
        for offset in 0..<hashes where peek(delimiter + offset) != hash { return false }
        return true
    }
}

// MARK: - Declarations

enum Kind {
    case type, member, initializer, subscripted
}

struct Declaration {
    var module: String
    var path: String
    var line: Int
    // nil for what isn't checked, only read for its signature.
    var access: String?
    var keyword: String
    var name: String
    var kind: Kind
    var enclosingType: String?
    // Words in its signature: parameter and return types, default arguments, conformances.
    var signature: Set<String>
    // The types its signature constructs.
    var constructs: Set<String>
}

struct SourceFile {
    var path: String
    var module: String
    var tokens: [Token]
    var imports: Set<String>
}

let sources = URL(fileURLWithPath: root).appendingPathComponent("Sources")
guard let walker = FileManager.default.enumerator(atPath: sources.path) else {
    fail("no Sources directory under \(root)")
}
var files: [SourceFile] = []
while let relative = walker.nextObject() as? String {
    guard relative.hasSuffix(".swift") else { continue }
    // Sources/<Tier>/<Module>/…
    let parts = relative.split(separator: "/")
    guard parts.count >= 3 else { fail("Sources/\(relative) isn't in a module directory") }
    guard let data = FileManager.default.contents(atPath: sources.path + "/" + relative) else {
        fail("can't read Sources/\(relative)")
    }
    let lexer = Lexer(bytes: [UInt8](data))
    lexer.code(inInterpolation: false)
    var imports: Set<String> = []
    for (index, token) in lexer.tokens.enumerated()
    where token.text == "import" && index + 1 < lexer.tokens.count {
        imports.insert(lexer.tokens[index + 1].text)
    }
    files.append(
        SourceFile(
            path: "Sources/" + relative, module: String(parts[1]), tokens: lexer.tokens,
            imports: imports))
}
files.sort { $0.path < $1.path }
if files.isEmpty { fail("no Swift files under \(sources.path)") }

var declarations: [Declaration] = []
var problems: [String] = []

for file in files {
    let tokens = file.tokens
    // One entry per open brace: the type whose body it opens, if any, what kind of type, and
    // where the body starts.
    var scopes: [(type: String?, keyword: String?, isPublic: Bool, start: Int)] = []
    var pending: (type: String, keyword: String, isPublic: Bool)?
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        if token.text == "{" {
            scopes.append((pending?.type, pending?.keyword, pending?.isPublic ?? false, index))
            pending = nil
            index += 1
            continue
        }
        if token.text == "}" {
            // A public protocol's requirements are all part of its signature.
            if let scope = scopes.popLast(), scope.isPublic, scope.keyword == "protocol" {
                declarations.append(
                    Declaration(
                        module: file.module, path: file.path, line: token.line, access: nil,
                        keyword: "protocol", name: "", kind: .member, enclosingType: nil,
                        signature: Set(tokens[scope.start..<index].map(\.text)),
                        constructs: constructed(tokens[scope.start..<index])))
            }
            index += 1
            continue
        }
        let nextText = index + 1 < tokens.count ? tokens[index + 1].text : ""
        if typeKeywords.contains(token.text) && startsName(nextText) {
            pending = (lastComponent(from: index + 1, in: tokens), token.text, false)
            index += 1
            continue
        }
        let inPublicEnum = scopes.last.map { $0.isPublic && $0.keyword == "enum" } ?? false
        let isCase = inPublicEnum && token.text == "case"
        guard
            isCase
                || (accessLevels.contains(token.text)
                    && (declarationKeywords.contains(nextText) || startsModifier(nextText)
                        || nextText == "@"))
        else {
            index += 1
            continue
        }
        let start = index
        var seen: Set<String> = []
        var before = start - 1
        while before >= 0, modifiers.contains(tokens[before].text) {
            seen.insert(tokens[before].text)
            before -= 1
        }
        index += 1
        while !isCase, index < tokens.count, !declarationKeywords.contains(tokens[index].text),
            modifiers.contains(tokens[index].text) || tokens[index].text == "@"
                || tokens[index - 1].text == "@"
        {
            seen.insert(tokens[index].text)
            index += 1
        }
        // The signature runs to the body's brace or the end of the statement.
        var end = index
        var depth = 0
        while end < tokens.count {
            let text = tokens[end].text
            if text == "(" || text == "[" { depth += 1 }
            if text == ")" || text == "]" { depth -= 1 }
            if depth == 0 && (text == "{" || text == "\n") { break }
            end += 1
        }
        let keyword = index < tokens.count ? tokens[index].text : ""
        let name = index + 1 < tokens.count ? tokens[index + 1].text : ""
        // Its own name doesn't make another declaration of that name used.
        var signature = Set(tokens[start..<end].map(\.text))
        if !isCase { signature.remove(name) }
        if !isCase && keyword == "extension" {
            problems.append(
                "\(file.path):\(token.line): write the access level on each member, not on the "
                    + "extension")
        }
        var kind = Kind.member
        if typeKeywords.contains(keyword) {
            kind = .type
            pending = (lastComponent(from: index + 1, in: tokens), keyword, true)
        } else if keyword == "init" {
            kind = .initializer
        } else if keyword == "subscript" {
            kind = .subscripted
        }
        // A member is no more visible than its type, so an access level there only misleads.
        if !isCase, let scope = scopes.last, let type = scope.type, !scope.isPublic,
            scope.keyword != "extension"
        {
            let member = kind == .member || kind == .type ? name : keyword
            problems.append(
                "\(file.path):\(token.line): \(token.text) \(keyword) \(type).\(member) is in an "
                    + "internal type; drop its access level")
            index = end
            continue
        }
        // A case, an override and a witness are public because something else is; an operator
        // is called by its symbol, which isn't a word.
        let isChecked =
            !isCase && !seen.contains("override") && !seen.contains("required")
            && !witnesses.contains(name) && !(keyword == "func" && !startsName(name))
            && !(keyword == "init"
                && signature.contains { witnessLabels.contains($0) || $0.hasSuffix("Literal") })
        declarations.append(
            Declaration(
                module: file.module, path: file.path, line: token.line,
                access: isChecked ? token.text : nil, keyword: keyword,
                name: kind == .member || kind == .type ? name : keyword, kind: kind,
                enclosingType: scopes.last(where: { $0.type != nil })?.type ?? nil,
                signature: signature, constructs: constructed(tokens[start..<end])))
        index = end
    }
}

// Whether a word can be a name: `class func` and `class var` declare members, not a class.
func startsName(_ text: String) -> Bool {
    guard let first = text.utf8.first, isIdentifierByte(first), first > 57 || first < 48 else {
        return false
    }
    return !declarationKeywords.contains(text) && !accessLevels.contains(text)
        && !modifiers.contains(text)
}

// `open(` and `package(` are calls; a modifier after an access level is a word.
func startsModifier(_ text: String) -> Bool {
    modifiers.contains(text) && text != "(" && text != ")"
}

// The words followed by `(`, a trailing closure's `{`, or `.init`.
func constructed(_ tokens: ArraySlice<Token>) -> Set<String> {
    var names: Set<String> = []
    for index in tokens.indices.dropLast() {
        let next = tokens[index + 1].text
        if next == "(" || next == "{"
            || (next == "." && index + 2 < tokens.endIndex && tokens[index + 2].text == "init")
        {
            names.insert(tokens[index].text)
        }
    }
    return names
}

// `extension Outer.Inner` opens Inner's body.
func lastComponent(from index: Int, in tokens: [Token]) -> String {
    var position = index
    while position + 2 < tokens.count && tokens[position + 1].text == "." {
        position += 2
    }
    return position < tokens.count ? tokens[position].text : ""
}

// MARK: - Uses

// A file sees the members of every module its module imports, directly or through another
// module, without importing them itself.
let modules = Set(files.map(\.module))
var imported: [String: Set<String>] = [:]
for file in files {
    imported[file.module, default: []].formUnion(file.imports.intersection(modules))
}
var visible: [String: Set<String>] = [:]
for module in modules {
    var seen: Set<String> = []
    var queue = Array(imported[module] ?? [])
    while let next = queue.popLast() {
        guard next != module, seen.insert(next).inserted else { continue }
        queue.append(contentsOf: imported[next] ?? [])
    }
    visible[module] = seen
}

// Per module: the words in other modules that see it, and the types they construct.
var wordsOutside: [String: Set<String>] = [:]
var constructedOutside: [String: Set<String>] = [:]
for file in files {
    let words = Set(file.tokens.map(\.text))
    let constructed = constructed(file.tokens[...])
    for module in visible[file.module] ?? [] {
        wordsOutside[module, default: []].formUnion(words)
        constructedOutside[module, default: []].formUnion(constructed)
    }
}

// Words in each module's signatures, with the declaration that holds them.
var signatures: [String: [(index: Int, words: Set<String>)]] = [:]
for (index, declaration) in declarations.enumerated() {
    signatures[declaration.module, default: []].append((index, declaration.signature))
}

// A protocol's requirements, which a type in a module the protocol's module doesn't import may
// fulfill.
var requirements: Set<String> = []
for declaration in declarations where declaration.access == nil && declaration.keyword == "protocol"
{
    requirements.formUnion(declaration.signature)
}

// MARK: - Allowlist

// One entry per line, `<Type>.<member> | <reason>`; `#` starts a comment line. An entry hides
// that member, which has to be public for a reason no caller shows: a framework protocol's
// requirement on a public type.
let allowFile = "scripts/surface-allow.txt"
guard let allowData = FileManager.default.contents(atPath: root + "/" + allowFile) else {
    fail("can't read \(allowFile)")
}
var allowed: [String: Int] = [:]  // key -> line number
for (offset, raw) in String(decoding: allowData, as: UTF8.self).components(separatedBy: "\n")
    .enumerated()
{
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let at = "\(allowFile):\(offset + 1):"
    let parts = line.components(separatedBy: " | ")
    guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else {
        problems.append("\(at) expected `<Type>.<member> | <reason>`")
        continue
    }
    let key = parts[0].trimmingCharacters(in: .whitespaces)
    guard key.split(separator: ".").count == 2, !key.contains(" ") else {
        problems.append("\(at) expected `<Type>.<member>`, not \(key)")
        continue
    }
    if let first = allowed[key] {
        problems.append("\(at) repeats line \(first)")
        continue
    }
    allowed[key] = offset + 1
}

// MARK: - Report

var checked = 0
var hidden: Set<String> = []
for (index, declaration) in declarations.enumerated() {
    guard let access = declaration.access else { continue }
    checked += 1
    let outside = wordsOutside[declaration.module] ?? []
    let used: Bool
    switch declaration.kind {
    case .initializer:
        let type = declaration.enclosingType ?? ""
        used =
            constructedOutside[declaration.module]?.contains(type) ?? false
            || signatures[declaration.module, default: []].contains {
                $0.index != index && declarations[$0.index].constructs.contains(type)
            }
    case .subscripted:
        used = outside.contains(declaration.enclosingType ?? "")
    case .type, .member:
        used =
            outside.contains(declaration.name) || requirements.contains(declaration.name)
            || signatures[declaration.module, default: []].contains {
                $0.index != index && $0.words.contains(declaration.name)
            }
    }
    if used { continue }
    let name = [declaration.enclosingType, declaration.name].compactMap { $0 }.joined(
        separator: ".")
    if allowed[name] != nil {
        hidden.insert(name)
        continue
    }
    problems.append(
        "\(declaration.path):\(declaration.line): \(access) \(declaration.keyword) \(name) has no "
            + "caller outside \(declaration.module)")
}
for (key, line) in allowed where !hidden.contains(key) {
    problems.append("\(allowFile):\(line): matches nothing, delete it: \(key)")
}

if problems.isEmpty {
    print(
        "\(checked) public and package declarations, each used outside its module or allowed (\(allowed.count) entries)"
    )
} else {
    for problem in problems.sorted() { print(problem) }
    exit(1)
}
