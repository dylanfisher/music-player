import Foundation

/// The text encodings tag formats use.
enum TextEncoding {
    case latin1
    /// Byte order from a leading byte-order mark, which must be there.
    case utf16WithBOM
    case utf16BigEndian
    case utf8

    /// `bytes` as text. Invalid text fails, naming `offset`, rather than turning into U+FFFD.
    func decode(_ bytes: [UInt8], at offset: Int) throws(ParseFailure) -> String {
        switch self {
        case .latin1: return Metadata.latin1(bytes)
        case .utf8: return try foundation(bytes, .utf8, at: offset)
        case .utf16BigEndian:
            return try foundation(bytes, .utf16BigEndian, at: offset)
        case .utf16WithBOM:
            if bytes.isEmpty { return "" }
            switch bytes.prefix(2) {
            case [0xFF, 0xFE]:
                return try foundation(
                    Array(bytes.dropFirst(2)), .utf16LittleEndian, at: offset)
            case [0xFE, 0xFF]:
                return try foundation(
                    Array(bytes.dropFirst(2)), .utf16BigEndian, at: offset)
            default: throw .malformed(at: offset, "UTF-16 text without a byte-order mark")
            }
        }
    }
}

private func foundation(
    _ bytes: [UInt8], _ encoding: String.Encoding, at offset: Int
) throws(ParseFailure) -> String {
    guard let text = String(bytes: bytes, encoding: encoding) else {
        throw .malformed(at: offset, "text isn't valid \(encoding == .utf8 ? "UTF-8" : "UTF-16")")
    }
    return text
}
