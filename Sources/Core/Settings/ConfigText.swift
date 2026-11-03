import Foundation

/// The config file's text: JSON with `//` and `/* */` comments, a comma after an object's or a
/// list's last item, and a UTF-8 byte order mark allowed. Every operation keeps each byte's
/// offset, so lines in errors are the file's own, and a patch changes only the text it has to.
struct ConfigText {
    private(set) var bytes: [UInt8] {
        didSet { newlines = newlineOffsets(bytes) }
    }
    /// Where each line break is, so finding a line costs a search, not a count from the start:
    /// a file with thousands of problems would otherwise take seconds to report them.
    private var newlines: [Int]

    init(_ text: String) {
        self.init(bytes: Array(text.utf8))
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
        newlines = newlineOffsets(bytes)
    }

    var string: String { String(decoding: bytes, as: UTF8.self) }

    /// The line `offset` is on, counting from 1.
    func line(at offset: Int) -> Int {
        // The line breaks before `offset`, plus one.
        var low = 0
        var high = newlines.count
        while low < high {
            let middle = (low + high) / 2
            if newlines[middle] < offset { low = middle + 1 } else { high = middle }
        }
        return low + 1
    }

    /// The file's own line ending, from its first line.
    var lineEnding: String {
        guard let end = bytes.firstIndex(of: newline) else { return "\n" }
        return end > 0 && bytes[end - 1] == carriageReturn ? "\r\n" : "\n"
    }

    // MARK: Plain JSON

    /// The text with every comment, trailing comma and the byte order mark turned to spaces,
    /// line breaks kept, so Foundation can parse it. Throws on a block comment that isn't
    /// closed, with its line.
    func plainJSON() throws(ConfigProblem) -> [UInt8] { try blanked().bytes }

    /// `plainJSON()`, and where the trailing commas it blanked were.
    private func blanked() throws(ConfigProblem) -> (bytes: [UInt8], commas: Set<Int>) {
        var out = bytes
        var commas: Set<Int> = []
        if out.starts(with: byteOrderMark) {
            for index in 0..<byteOrderMark.count { out[index] = space }
        }
        var index = 0
        var inString = false
        /// Where the last item ended, so a comma is blanked only when an item comes before it.
        var lastSignificant: UInt8?
        var pendingComma: Int?
        while index < out.count {
            let byte = out[index]
            if inString {
                if byte == backslash {
                    index += 2
                    continue
                }
                if byte == quote { inString = false }
                index += 1
                continue
            }
            if byte == slash, index + 1 < out.count, out[index + 1] == slash {
                while index < out.count, out[index] != newline {
                    out[index] = space
                    index += 1
                }
                continue
            }
            if byte == slash, index + 1 < out.count, out[index + 1] == star {
                let start = index
                index += 2
                while index < out.count,
                    !(out[index] == star && index + 1 < out.count
                        && out[index + 1] == slash)
                {
                    index += 1
                }
                guard index < out.count else {
                    throw ConfigProblem(
                        line: line(at: start), message: "a /* comment is never closed")
                }
                for blank in start...(index + 1)
                where out[blank] != newline
                    && out[blank] != carriageReturn
                {
                    out[blank] = space
                }
                index += 2
                continue
            }
            if isWhitespace(byte) {
                index += 1
                continue
            }
            if byte == commaByte, let last = lastSignificant,
                ![openBrace, openBracket, commaByte].contains(last)
            {
                pendingComma = index
            } else if byte == commaByte {
                // A second comma in a row isn't a trailing one. Both stay, so the parse fails;
                // Foundation would take the second as trailing once the first was blanked.
                pendingComma = nil
            } else if byte == closeBrace || byte == closeBracket, let comma = pendingComma {
                out[comma] = space
                commas.insert(comma)
            }
            if byte != commaByte { pendingComma = nil }
            if byte == quote { inString = true }
            lastSignificant = byte
            index += 1
        }
        return (out, commas)
    }

    // MARK: Scanning

    /// An object's members with where their text is, found in text that already parsed.
    struct Object {
        var open: Int
        var close: Int
        var members: [Member]

        func member(_ key: String) -> Member? { members.first { $0.key == key } }
    }

    struct Member {
        var key: String
        var keyStart: Int
        var valueStart: Int
        /// One past the value's last byte.
        var valueEnd: Int
        /// The comma after the value, if any.
        var comma: Int?
        /// The value, when it's an object.
        var object: Object?
    }

    /// The top-level object, and every key an object has twice, at any depth, by the offset of
    /// its second appearance. Only for text whose `plainJSON()` Foundation has parsed.
    func scan() throws(ConfigProblem) -> (object: Object, duplicates: [(key: String, offset: Int)])
    {
        let (plain, commas) = try blanked()
        var scanner = Scanner(bytes: plain, trailingCommas: commas)
        scanner.skipWhitespace()
        let object = scanner.object()
        return (object, scanner.duplicates)
    }

    private struct Scanner {
        let bytes: [UInt8]
        /// Trailing commas `blanked()` turned to spaces, which the scan still reports.
        let trailingCommas: Set<Int>
        var index = 0
        var duplicates: [(key: String, offset: Int)] = []

        mutating func skipWhitespace() {
            while index < bytes.count, isWhitespace(bytes[index]), !trailingCommas.contains(index) {
                index += 1
            }
        }

        mutating func object() -> Object {
            precondition(bytes[index] == openBrace, "the scan reads only parsed JSON")
            let open = index
            index += 1
            var members: [Member] = []
            var seen: Set<String> = []
            skipWhitespace()
            while bytes[index] != closeBrace {
                let keyStart = index
                let key = string()
                if !seen.insert(key).inserted { duplicates.append((key, keyStart)) }
                skipWhitespace()
                index += 1  // the colon
                skipWhitespace()
                let valueStart = index
                let nested = value()
                let valueEnd = index
                skipWhitespace()
                var comma: Int?
                if bytes[index] == commaByte || trailingCommas.contains(index) {
                    comma = index
                    index += 1
                    skipWhitespace()
                }
                members.append(
                    Member(
                        key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd,
                        comma: comma, object: nested))
            }
            let close = index
            index += 1
            return Object(open: open, close: close, members: members)
        }

        /// Skips a value, returning it when it's an object.
        mutating func value() -> Object? {
            switch bytes[index] {
            case openBrace:
                return object()
            case openBracket:
                index += 1
                skipWhitespace()
                while bytes[index] != closeBracket {
                    _ = value()
                    skipWhitespace()
                    if bytes[index] == commaByte || trailingCommas.contains(index) { index += 1 }
                    skipWhitespace()
                }
                index += 1
            case quote:
                _ = string()
            default:
                while index < bytes.count, !isWhitespace(bytes[index]),
                    ![commaByte, closeBrace, closeBracket].contains(bytes[index])
                {
                    index += 1
                }
            }
            return nil
        }

        mutating func string() -> String {
            let start = index
            index += 1
            while bytes[index] != quote {
                index += bytes[index] == backslash ? 2 : 1
            }
            index += 1
            let token = Data(bytes[start..<index])
            // The scan runs on parsed JSON, so a string token always decodes.
            return (try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed))
                as? String ?? ""
        }
    }

    // MARK: Patches

    /// Replaces a member's value with `text`.
    mutating func replaceValue(of member: Member, with text: String) {
        bytes.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(text.utf8))
    }

    /// Adds `"key": value` as the last member of `object`, with `comment` lines above it, at the
    /// indent of the member before it. An object written on one line gets it on that line with
    /// no comment; an empty one is opened onto lines of its own.
    mutating func insert(key: String, value: String, comment: [String], into object: Object) {
        let ending = lineEnding
        let keyText = jsonString(key)
        if let last = object.members.last {
            if line(at: object.open) == line(at: object.close) {
                let text =
                    (last.comma == nil ? ", " : " ") + "\(keyText): \(value)"
                    + (last.comma == nil ? "" : ",")
                let at = last.comma.map { $0 + 1 } ?? last.valueEnd
                bytes.insert(contentsOf: Array(text.utf8), at: at)
                return
            }
            let indent = indentation(at: last.keyStart)
            let lines =
                comment.map { indent + "// " + $0 } + [
                    indent + "\(keyText): \(reindent(value, by: indent))"
                        + (last.comma == nil ? "" : ",")
                ]
            // After the last member's line, unless the object closes on it.
            let end = last.comma.map { $0 + 1 } ?? last.valueEnd
            let after = line(at: end) == line(at: object.close) ? end : endOfLine(from: end)
            bytes.insert(
                contentsOf: Array((ending + lines.joined(separator: ending)).utf8), at: after)
            if last.comma == nil { bytes.insert(commaByte, at: last.valueEnd) }
            return
        }
        let outer = indentation(at: object.open)
        let indent = outer + "  "
        let lines =
            comment.map { indent + "// " + $0 } + [
                indent + "\(keyText): \(reindent(value, by: indent))"
            ]
        bytes.replaceSubrange(
            (object.open + 1)..<object.close,
            with: Array((ending + lines.joined(separator: ending) + ending + outer).utf8))
    }

    /// Takes a member out with its comma, and its line when nothing else is on it. Comments
    /// around it stay, unless `withComment`: then a `//` comment after it on its line and the
    /// `//` lines directly above it go too.
    mutating func remove(_ member: Member, from object: Object, withComment: Bool = false) {
        guard let position = object.members.firstIndex(where: { $0.keyStart == member.keyStart })
        else { return }
        var start = member.keyStart
        var end = member.comma.map { $0 + 1 } ?? member.valueEnd
        let lineStart = startOfLine(at: start)
        let lineEnd = endOfLine(from: end)
        let rest = bytes[end..<lineEnd].drop(while: isWhitespace)
        if bytes[lineStart..<start].allSatisfy(isWhitespace),
            rest.isEmpty || (withComment && isLineComment(rest))
        {
            start = lineStart
            while withComment, start > 0 {
                let above = startOfLine(at: start - 1)
                guard isLineComment(bytes[above..<(start - 1)].drop(while: isWhitespace)) else {
                    break
                }
                start = above
            }
            // Past the line break, a carriage return's too.
            end = bytes[lineEnd...].firstIndex(of: newline).map { $0 + 1 } ?? bytes.count
            if start > 0, end == bytes.count, bytes[start - 1] == newline { start -= 1 }
        }
        bytes.removeSubrange(start..<end)
        // The last member's comma goes with it, unless the file ends items with commas.
        if member.comma == nil, position > 0, let comma = object.members[position - 1].comma {
            bytes.remove(at: comma)
        }
    }

    private func isLineComment(_ text: ArraySlice<UInt8>) -> Bool {
        text.starts(with: [slash, slash])
    }

    private func indentation(at offset: Int) -> String {
        let start = startOfLine(at: offset)
        var end = start
        while end < bytes.count, bytes[end] == space || bytes[end] == tab { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func startOfLine(at offset: Int) -> Int {
        var index = offset
        while index > 0, bytes[index - 1] != newline { index -= 1 }
        return index
    }

    /// The offset of the line break that ends the line `offset` is on, or the end, before a
    /// carriage return.
    private func endOfLine(from offset: Int) -> Int {
        var index = offset
        while index < bytes.count, bytes[index] != newline { index += 1 }
        if index > offset, index > 0, bytes[index - 1] == carriageReturn { index -= 1 }
        return index
    }

    /// A multi-line value's later lines, moved to sit under its key.
    private func reindent(_ value: String, by indent: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { $0.offset == 0 ? String($0.element) : indent + $0.element }
            .joined(separator: lineEnding)
    }
}

private func newlineOffsets(_ bytes: [UInt8]) -> [Int] {
    bytes.indices.filter { bytes[$0] == newline }
}

func jsonString(_ text: String) -> String {
    // A String always serializes.
    String(
        decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
        as: UTF8.self)
}

private func isWhitespace(_ byte: UInt8) -> Bool {
    byte == space || byte == tab || byte == newline || byte == carriageReturn
}

private let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")
private let newline = UInt8(ascii: "\n")
private let carriageReturn = UInt8(ascii: "\r")
private let quote = UInt8(ascii: "\"")
private let backslash = UInt8(ascii: "\\")
private let slash = UInt8(ascii: "/")
private let star = UInt8(ascii: "*")
private let commaByte = UInt8(ascii: ",")
private let openBrace = UInt8(ascii: "{")
private let closeBrace = UInt8(ascii: "}")
private let openBracket = UInt8(ascii: "[")
private let closeBracket = UInt8(ascii: "]")
