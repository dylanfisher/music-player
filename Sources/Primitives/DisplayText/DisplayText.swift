/// 312.4 -> "5:12", 3725 -> "1:02:05".
public func clock(_ seconds: Double) -> String {
    let whole = Int(max(0, seconds))
    let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
    let tail = (rest < 10 ? "0" : "") + String(rest)
    if hours > 0 { return "\(hours):" + (minutes < 10 ? "0" : "") + "\(minutes):" + tail }
    return "\(minutes):" + tail
}

/// 44100 -> "44.1", 96000 -> "96", 705600 -> "705.6".
public func kilohertz(_ hertz: Double) -> String {
    let khz = hertz / 1000
    return khz.rounded() == khz ? String(Int(khz)) : String(khz)
}

/// 44100...44100 -> "44.1", 44100...192000 -> "44.1–192".
public func kilohertz(_ range: ClosedRange<Double>) -> String {
    range.lowerBound == range.upperBound
        ? kilohertz(range.lowerBound)
        : "\(kilohertz(range.lowerBound))–\(kilohertz(range.upperBound))"
}

/// 24 -> "24-bit".
public func bitDepth(_ bits: some BinaryInteger) -> String { "\(bits)-bit" }

/// "24-bit int", "32-bit float".
public func sampleType(bits: some BinaryInteger, isFloat: Bool) -> String {
    "\(bitDepth(bits)) \(isFloat ? "float" : "int")"
}

/// A format as the signal path and the status line show it: "44.1 kHz · 16-bit", "48 kHz ·
/// 32-bit float", or "44.1 kHz" with no depth, as for a lossy file.
public func formatText(rateHz: Double, bits: UInt32?, isFloat: Bool) -> String {
    let depth = bits.map { " · " + depthText(bits: $0, isFloat: isFloat) } ?? ""
    return "\(kilohertz(rateHz)) kHz\(depth)"
}

/// "24-bit", "32-bit float".
public func depthText(bits: UInt32, isFloat: Bool) -> String {
    bitDepth(bits) + (isFloat ? " float" : "")
}

/// 3 -> "★★★"; 0, unrated, -> "".
public func stars(_ count: Int) -> String {
    String(repeating: "★", count: max(0, count))
}

/// `text` as one line for a terminal. A file name or a tag can hold control characters, which
/// would move the cursor, retitle the window or write the clipboard, or a line break, which
/// would print a line that looks like the app's own; each prints as `\u{1B}`, `\u{A}` and so on.
public func terminalSafe(_ text: String) -> String {
    var safe = ""
    for scalar in text.unicodeScalars {
        if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
            safe += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
        } else {
            safe.unicodeScalars.append(scalar)
        }
    }
    return safe
}

/// SF Symbol names more than one view draws.
public enum SymbolName {
    public static let playlist = "music.note.list"
    /// Something the owner should look at: a problem count, an unreadable playlist.
    public static let problem = "exclamationmark.triangle"
}
