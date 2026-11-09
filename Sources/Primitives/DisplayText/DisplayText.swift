import Foundation

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

/// 16012.3 -> "16.0": a measured frequency to a tenth of a kilohertz, where `kilohertz`
/// gives a rate exactly.
public func kilohertzText(_ hertz: Double) -> String {
    String(format: "%.1f", hertz / 1000)
}

/// 16012.3 -> "16.0 kHz": `kilohertzText` with its unit.
public func kilohertzLabel(_ hertz: Double) -> String { "\(kilohertzText(hertz)) kHz" }

/// 0.43 -> "+0.4 dBTP": a true peak, signed, to a tenth of a decibel.
public func truePeakText(_ decibels: Double) -> String {
    String(format: "%+.1f dBTP", decibels)
}

/// 10 -> "DR10": a dynamic range score as the DR meters print it.
public func dynamicRangeText(_ score: Int) -> String { "DR\(score)" }

/// 44100...44100 -> "44.1", 44100...192000 -> "44.1–192".
public func kilohertz(_ range: ClosedRange<Double>) -> String {
    range.lowerBound == range.upperBound
        ? kilohertz(range.lowerBound)
        : "\(kilohertz(range.lowerBound))–\(kilohertz(range.upperBound))"
}

/// 320.4 -> "320 kbps".
public func kbpsText(_ kilobitsPerSecond: Double) -> String {
    "\(Int(kilobitsPerSecond.rounded())) kbps"
}

/// 44_812_345 -> "44.8 MB": a file's size, as the Finder shows it.
public func fileSizeText(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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

/// 1 -> "mono", 2 -> "stereo", 6 -> "6 channels".
public func channelsText(_ count: some BinaryInteger) -> String {
    switch count {
    case 1: "mono"
    case 2: "stereo"
    default: "\(count) channels"
    }
}

/// 1204 -> "1,204", in the user's locale.
public func number(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

/// "1 track", "1,204 tracks": the one spelling of the noun every count of tracks uses.
public func tracks(_ value: Int) -> String { count(value, "track") }

/// "1 file", "1,204 files": the one spelling of the noun every count of files uses.
public func files(_ value: Int) -> String { count(value, "file") }

/// "1 album", "1,204 albums": `noun` after the count, plural but for one.
public func count(_ value: Int, _ noun: String) -> String {
    "\(number(value)) \(noun)\(value == 1 ? "" : "s")"
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
    /// Pause and play: playback's buttons, and the status bar's for a scan or Analyze Library.
    public static let pause = "pause.fill"
    public static let play = "play.fill"
}

/// Whether white text has more contrast than black on an opaque sRGB color, each component
/// from 0 to 1, by WCAG 2's relative luminance: white wins below a luminance of about 0.18.
func prefersWhiteText(red: Double, green: Double, blue: Double) -> Bool {
    func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    // Contrast is (lighter + 0.05) / (darker + 0.05); white's luminance is 1, black's 0.
    return 1.05 / (luminance + 0.05) > (luminance + 0.05) / 0.05
}
