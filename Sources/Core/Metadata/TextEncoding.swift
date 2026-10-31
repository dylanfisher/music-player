import Foundation

/// The text encodings tag formats use.
enum TextEncoding {
    case latin1
    /// Byte order from a leading byte-order mark.
    case utf16WithBOM
    case utf16BigEndian
    case utf8

    /// `bytes` as text. Text that isn't valid in this encoding is still read, with a warning:
    /// invalid UTF-8 as Latin-1, since that's almost always what a mislabelled tag holds, and
    /// invalid UTF-16 with U+FFFD for the broken characters, since it has no other reading.
    func decode(_ bytes: [UInt8], at offset: Int, warnings: inout [MetadataWarning]) -> String {
        switch self {
        case .latin1: return Metadata.latin1(bytes)
        case .utf8:
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            warnings.append(
                MetadataWarning(
                    kind: .badText, offset: offset,
                    detail: "text isn't valid UTF-8; read as Latin-1"))
            return Metadata.latin1(bytes)
        case .utf16BigEndian:
            return utf16(bytes, bigEndian: true, at: offset, &warnings)
        case .utf16WithBOM:
            switch bytes.prefix(2) {
            case []: return ""
            case [0xFF, 0xFE]:
                return utf16(Array(bytes.dropFirst(2)), bigEndian: false, at: offset, &warnings)
            case [0xFE, 0xFF]:
                return utf16(Array(bytes.dropFirst(2)), bigEndian: true, at: offset, &warnings)
            default:
                // Windows taggers write little-endian without the mark.
                warnings.append(
                    MetadataWarning(
                        kind: .badText, offset: offset,
                        detail: "UTF-16 text without a byte-order mark; read as little-endian"))
                return utf16(bytes, bigEndian: false, at: offset, &warnings)
            }
        }
    }
}

private func utf16(
    _ bytes: [UInt8], bigEndian: Bool, at offset: Int, _ warnings: inout [MetadataWarning]
) -> String {
    let units = stride(from: 0, to: bytes.count - 1, by: 2).map { index in
        bigEndian
            ? UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            : UInt16(bytes[index + 1]) << 8 | UInt16(bytes[index])
    }
    let text = String(decoding: units, as: UTF16.self)
    // Decoding replaces each unpaired surrogate, so the text no longer matches the units.
    if bytes.count % 2 != 0 || !text.utf16.elementsEqual(units) {
        warnings.append(
            MetadataWarning(
                kind: .badText, offset: offset,
                detail: "text isn't valid UTF-16; broken characters replaced"))
    }
    return text
}
