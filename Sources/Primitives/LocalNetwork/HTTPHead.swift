import Foundation

/// The start line and header fields of an HTTP message, as SSDP replies, HTTP replies and the
/// server's requests all have them.
struct HTTPHead: Equatable {
    /// The start line's three parts: method, target and version, or version, status and reason.
    var start: [String]
    /// Field names lowercased, in order.
    var fields: [(name: String, value: String)]

    static func == (a: HTTPHead, b: HTTPHead) -> Bool {
        a.start == b.start && a.fields.elementsEqual(b.fields) { $0 == $1 }
    }

    /// Most fields any message may have.
    static let fieldCap = 100

    static let version = "HTTP/1.1"
    /// Field names, lowercased as `fields` holds them.
    static let contentLength = "content-length"
    static let transferEncoding = "transfer-encoding"

    enum Parse: Equatable {
        /// The head goes on past the bytes so far, which are under the cap.
        case incomplete
        case tooLarge
        case malformed(String)
        /// The head and how many bytes it took, its blank line included.
        case head(HTTPHead, length: Int)
    }

    /// Reads the head at the start of `bytes`, up to `cap` bytes. Lines end in CRLF or a bare
    /// LF. Only printable ASCII and tabs are allowed, and a folded line is refused.
    static func parse(_ bytes: ArraySlice<UInt8>, cap: Int) -> Parse {
        var lines: [ArraySlice<UInt8>] = []
        var lineStart = bytes.startIndex
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if index - bytes.startIndex >= cap { return .tooLarge }
            if bytes[index] == lf {
                var line = bytes[lineStart..<index]
                if line.last == cr { line = line.dropLast() }
                if line.isEmpty {
                    return lines.isEmpty
                        ? .malformed("it starts with a blank line")
                        : head(lines, length: index + 1 - bytes.startIndex)
                }
                lines.append(line)
                lineStart = index + 1
            }
            index += 1
        }
        return bytes.count > cap ? .tooLarge : .incomplete
    }

    private static func head(_ lines: [ArraySlice<UInt8>], length: Int) -> Parse {
        for line in lines {
            if let bad = line.first(where: { ($0 < 0x20 && $0 != 0x09) || $0 > 0x7E }) {
                return .malformed("it has the byte \(bad)")
            }
        }
        let start = lines[0].split(separator: space, maxSplits: 2, omittingEmptySubsequences: false)
        guard start.count == 3, start.allSatisfy({ !$0.isEmpty }) else {
            return .malformed("its first line isn't three parts")
        }
        guard lines.count - 1 <= fieldCap else { return .malformed("over \(fieldCap) fields") }
        var fields: [(String, String)] = []
        for line in lines.dropFirst() {
            guard line.first != space, line.first != 0x09 else {
                return .malformed("a field is folded onto a second line")
            }
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > line.startIndex,
                line[..<colon].allSatisfy(isTokenByte)
            else { return .malformed("a field has no name") }
            let value = String(decoding: line[(colon + 1)...], as: UTF8.self)
                .trimmingCharacters(in: [" ", "\t"])
            fields.append((String(decoding: line[..<colon], as: UTF8.self).lowercased(), value))
        }
        return .head(
            HTTPHead(start: start.map { String(decoding: $0, as: UTF8.self) }, fields: fields),
            length: length)
    }

    /// The values of every field named `name`, any case.
    func values(_ name: String) -> [String] {
        let lowered = name.lowercased()
        return fields.filter { $0.name == lowered }.map(\.value)
    }

    /// The value of the one field named `name`; nil when there's none or more than one.
    func value(_ name: String) -> String? {
        let found = values(name)
        return found.count == 1 ? found[0] : nil
    }
}

private let cr = UInt8(ascii: "\r")
private let lf = UInt8(ascii: "\n")
private let space = UInt8(ascii: " ")

/// RFC 9110's token characters, which a field name is made of.
private func isTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"):
        true
    default:
        Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
    }
}
