import Foundation
import Metadata

/// A playlist file's entries, read as hostile input (ADR 0025): capped in size, line length,
/// entries and problems, and only ever turned into paths, which nothing here opens or stats.
public struct PlaylistFile: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        case m3u, m3u8, pls

        /// The format a file's extension names, in any case.
        public init?(fileExtension: String) { self.init(rawValue: fileExtension.lowercased()) }
    }

    /// Far over any real playlist (43k tracks in M3U8 is about 6 MiB), and read whole.
    public static let maximumBytes = 16 << 20
    /// Four times macOS's `PATH_MAX`, room for a percent-escaped `file:` URL.
    static let maximumLineBytes = 4096
    static let maximumEntries = 100_000
    /// Entries, comments and blank lines together.
    static let maximumLines = 2 * maximumEntries
    /// Problems kept in `problems`; the rest are counted.
    public static let maximumProblems = 100

    /// Absolute, with `.` and `..` folded, in the file's order. Unicode form as written.
    public var paths: [String] = []
    public var problems: [PlaylistFileProblem] = []
    public var unlistedProblemCount = 0

    /// Reads `bytes` as `format`. Relative entries are taken from `folder`, the playlist file's
    /// own. `.m3u8` is UTF-8; `.m3u` and `.pls` are UTF-8 when the whole file is, else
    /// Windows-1252, which covers Latin-1 (ADR 0032).
    public init(_ bytes: [UInt8], format: Format, folder: String) throws(PlaylistFileError) {
        guard bytes.count <= Self.maximumBytes else { throw .tooLarge(bytes.count) }
        var body = bytes[...]
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBOM = body.starts(with: bom)
        if hasBOM { body = body.dropFirst(bom.count) }
        if body.starts(with: [0xFF, 0xFE]) || body.starts(with: [0xFE, 0xFF]) {
            throw .utf16
        }
        let utf8 = hasBOM || format == .m3u8 || utf8Text(body) != nil
        var numbered: [(number: Int, path: String)] = []
        var lines = Lines(body)
        var lineNumber = 0
        reading: while let line = lines.next() {
            lineNumber += 1
            // Blank lines and comments cost a turn each too, so lines are capped apart from
            // entries.
            guard lineNumber <= Self.maximumLines else {
                note(PlaylistFileProblem(line: lineNumber, .tooManyLines))
                break
            }
            if line.first == UInt8(ascii: "#") { continue }
            guard line.count <= Self.maximumLineBytes else {
                note(PlaylistFileProblem(line: lineNumber, .lineTooLong))
                continue
            }
            guard let text = utf8 ? utf8Text(line) : windows1252(line),
                !text.unicodeScalars.contains("\0")
            else {
                note(PlaylistFileProblem(line: lineNumber, .invalidText))
                continue
            }
            if text.allSatisfy(\.isWhitespace) { continue }
            let entry: Substring
            var order = numbered.count
            if format == .pls {
                switch plsEntry(text) {
                case .ignored: continue
                case .unknown:
                    note(PlaylistFileProblem(line: lineNumber, .unknownLine))
                    continue
                case .file(let number, let value):
                    order = number
                    entry = value
                }
            } else {
                entry = text[...]
            }
            let path: String
            switch PlaylistEntry(entry) {
            case .absolute(let absolute): path = folded(absolute)
            case .relative(let relative): path = folded(folder + "/" + relative)
            case .problem(let kind):
                note(PlaylistFileProblem(line: lineNumber, kind))
                continue
            }
            guard numbered.count < Self.maximumEntries else {
                note(PlaylistFileProblem(line: lineNumber, .tooManyEntries))
                break reading
            }
            numbered.append((order, path))
        }
        // PLS numbers its entries; a stable sort keeps the file's order among equal numbers.
        paths = numbered.enumerated()
            .sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }
            .map(\.element.path)
    }

    private mutating func note(_ problem: PlaylistFileProblem) {
        if problems.count < Self.maximumProblems {
            problems.append(problem)
        } else {
            unlistedProblemCount += 1
        }
    }

    /// Reads the playlist file at `url` without following a link, and only if it's a regular
    /// file under `maximumBytes`. Its format comes from its extension.
    public init(contentsOf url: URL) throws(PlaylistFileError) {
        guard let format = Format(fileExtension: url.pathExtension) else {
            throw .unknownFormat(url.pathExtension)
        }
        let source: FileSource
        do throws(ParseFailure) {
            source = try FileSource(path: url.path, hints: .none)
        } catch {
            throw .unreadable(error.detail)
        }
        guard source.size <= Self.maximumBytes else { throw .tooLarge(source.size) }
        let bytes: [UInt8]
        do throws(ParseFailure) {
            bytes = try source.read(0..<source.size)
        } catch {
            throw .unreadable(error.detail)
        }
        try self.init(bytes, format: format, folder: url.deletingLastPathComponent().path)
    }
}

/// A playlist file the app won't read at all.
public enum PlaylistFileError: Error, Equatable, CustomStringConvertible {
    case tooLarge(Int)
    case utf16
    case unknownFormat(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .tooLarge(let bytes):
            "it's \(bytes) bytes; playlist files over \(PlaylistFile.maximumBytes) aren't read"
        case .utf16: "it's UTF-16 text; save it as UTF-8 (M3U8)"
        case .unknownFormat(let name):
            "\".\(name)\" isn't a playlist file; the app reads "
                + PlaylistFile.Format.allCases.map { "." + $0.rawValue }.joined(separator: ", ")
        case .unreadable(let detail): "it can't be read: \(detail)"
        }
    }
}

/// What one entry line names.
enum PlaylistEntry: Equatable {
    case absolute(String)
    case relative(String)
    case problem(PlaylistFileProblem.Kind)

    init(_ text: Substring) {
        if text.hasPrefix("/") {
            self = .absolute(String(text))
            return
        }
        let scheme = text.prefix {
            $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0))
        }
        let rest = text.dropFirst(scheme.count)
        guard rest.hasPrefix(":"), let first = scheme.first, first.isLetter else {
            self = .relative(String(text))
            return
        }
        if scheme.count == 1, rest.dropFirst().hasPrefix("\\") || rest.dropFirst().hasPrefix("/") {
            self = .problem(.windowsPath)
        } else if scheme.lowercased() == "file" {
            self = fileURLPath(rest.dropFirst()).map { .absolute($0) } ?? .problem(.badFileURL)
        } else if rest.dropFirst().hasPrefix("//") {
            self = .problem(.scheme(String(scheme)))
        } else {
            // "Live: 1999/a.flac" is a relative path with a colon in a folder name, not a URL.
            self = .relative(String(text))
        }
    }
}

/// The path of a `file:` URL after the colon: `///path`, `//localhost/path` or `/path`, with
/// `%` escapes decoded as UTF-8. Nil for another host or a broken escape.
private func fileURLPath(_ text: Substring) -> String? {
    var rest = text
    if rest.hasPrefix("//") {
        rest = rest.dropFirst(2)
        let host = rest.prefix { $0 != "/" }
        guard host.isEmpty || host.lowercased() == "localhost" else { return nil }
        rest = rest.dropFirst(host.count)
    }
    guard rest.hasPrefix("/") else { return nil }
    var bytes: [UInt8] = []
    var utf8 = Array(rest.utf8)[...]
    while let byte = utf8.popFirst() {
        guard byte == UInt8(ascii: "%") else {
            bytes.append(byte)
            continue
        }
        guard utf8.count >= 2, let high = hexValue(utf8.removeFirst()),
            let low = hexValue(utf8.removeFirst())
        else { return nil }
        bytes.append(high << 4 | low)
    }
    guard let path = utf8Text(bytes[...]), !path.unicodeScalars.contains("\0")
    else {
        return nil
    }
    return path
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
}

/// An absolute path with empty and `.` components dropped and `..` taken off the one before,
/// by text alone: the disk isn't asked, so a link in the path isn't followed.
func folded(_ path: String) -> String {
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".": continue
        case "..": _ = components.popLast()
        default: components.append(component)
        }
    }
    return "/" + components.joined(separator: "/")
}

/// The lines of `bytes`, one at a time, ended by LF, CRLF or a lone CR, as classic Mac OS wrote
/// them. Lazy, so a file of line breaks costs no more memory than its bytes.
private struct Lines: IteratorProtocol {
    private let bytes: ArraySlice<UInt8>
    private var start: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        start = bytes.startIndex
    }

    mutating func next() -> ArraySlice<UInt8>? {
        guard start < bytes.endIndex else { return nil }
        var index = start
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                let line = bytes[start..<index]
                let crlf =
                    byte == UInt8(ascii: "\r") && index + 1 < bytes.endIndex
                    && bytes[index + 1] == UInt8(ascii: "\n")
                start = index + (crlf ? 2 : 1)
                return line
            }
            index += 1
        }
        defer { start = bytes.endIndex }
        return bytes[start...]
    }
}

/// What a PLS line says.
private enum PLSLine {
    case ignored
    case unknown
    case file(Int, Substring)
}

/// `[playlist]`, `;` comments and the title, length, count and version keys are ignored;
/// `FileN=` is an entry.
private func plsEntry(_ text: String) -> PLSLine {
    if text.lowercased() == "[playlist]" || text.hasPrefix(";") { return .ignored }
    guard let equals = text.firstIndex(of: "=") else { return .unknown }
    let key = text[..<equals].lowercased()
    let value = text[text.index(after: equals)...]
    for ignored in ["title", "length"] where key.hasPrefix(ignored) {
        if Int(key.dropFirst(ignored.count)) != nil { return .ignored }
    }
    if key == "numberofentries" || key == "version" { return .ignored }
    guard key.hasPrefix("file"), let number = Int(key.dropFirst(4)) else { return .unknown }
    return .file(number, value)
}

/// `bytes` as UTF-8, or nil if they aren't. Foundation's `String(bytes:encoding:)` would drop a
/// leading U+FEFF, which within a file is part of the line.
private func utf8Text(_ bytes: ArraySlice<UInt8>) -> String? {
    let text = String(decoding: bytes, as: UTF8.self)
    return text.utf8.elementsEqual(bytes) ? text : nil
}

/// Windows-1252, total: the five bytes it leaves undefined map to the C1 controls, as Latin-1
/// does, so no line is refused for its encoding.
private func windows1252(_ bytes: ArraySlice<UInt8>) -> String {
    var scalars = String.UnicodeScalarView()
    for byte in bytes {
        let value =
            (0x80...0x9F).contains(byte) ? windows1252High[Int(byte) - 0x80] : UInt32(byte)
        scalars.append(Unicode.Scalar(value)!)
    }
    return String(scalars)
}

/// 0x80 to 0x9F in Windows-1252.
private let windows1252High: [UInt32] = [
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
]
