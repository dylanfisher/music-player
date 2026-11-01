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

/// 24 -> "24-bit".
public func bitDepth(_ bits: some BinaryInteger) -> String { "\(bits)-bit" }

/// 3 -> "★★★"; 0, unrated, -> "".
public func stars(_ count: Int) -> String {
    String(repeating: "★", count: max(0, count))
}

/// `text` for a terminal. A file name or a tag can hold control characters, which would move the
/// cursor, retitle the window or write the clipboard, so each one but a newline or a tab prints
/// as `\u{1B}` and so on.
public func terminalSafe(_ text: String) -> String {
    var safe = ""
    for scalar in text.unicodeScalars {
        let isControl = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        if isControl, scalar != "\n", scalar != "\t" {
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
}
