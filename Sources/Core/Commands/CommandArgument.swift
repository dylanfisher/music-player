import Foundation

/// How Seek To and Set Volume read their arguments: a plain decimal number, nothing else, so a
/// remote's or a script's mistake is refused rather than read as something near it.
public enum CommandArgument {
    /// The most Seek To takes, a day: no track is longer.
    static let maximumSeconds = 86_400.0

    /// Seek To's: seconds from 0 to a day.
    public static func seconds(_ text: String) -> Double? {
        number(text).flatMap { (0...maximumSeconds).contains($0) ? $0 : nil }
    }

    /// Set Volume's: decibels within `range`.
    public static func decibels(_ text: String, in range: ClosedRange<Double>) -> Double? {
        number(text).flatMap { range.contains($0) ? $0 : nil }
    }

    /// Digits with an optional sign and fraction, at most 16 characters.
    private static func number(_ text: String) -> Double? {
        let digits = text.drop { $0 == "-" || $0 == "+" }
        guard text.count <= 16, text.count - digits.count <= 1, !digits.isEmpty,
            digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            digits.filter({ $0 == "." }).count <= 1, digits.first != ".", digits.last != "."
        else { return nil }
        return Double(text)
    }
}
