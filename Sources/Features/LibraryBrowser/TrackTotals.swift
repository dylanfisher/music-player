import DisplayText
import Foundation
import Library

extension TrackTotals {
    /// "43,400 tracks, 1048.1 GiB, 185 days 17 hours 29 minutes 26 seconds", as Swinsian puts it,
    /// or "1 track selected, …" for a selection.
    func text(selected: Bool = false) -> String {
        [
            tracks(count) + (selected ? " selected" : ""), binarySize(sizeBytes),
            spokenDuration(durationSeconds),
        ].joined(separator: ", ")
    }
}

/// "512 bytes", "303.5 MiB", "1048.1 GiB": binary units to one decimal, up to GiB, as Swinsian
/// shows them.
func binarySize(_ bytes: Int) -> String {
    guard bytes >= 1024 else { return count(bytes, "byte") }
    let units = ["KiB", "MiB", "GiB"]
    var value = Double(bytes) / 1024
    var unit = 0
    // Compared as shown, so 1,048,575 bytes is "1.0 MiB", not "1024.0 KiB".
    while (value * 10).rounded() / 10 >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    let number = value.formatted(.number.precision(.fractionLength(1)).grouping(.never))
    return "\(number) \(units[unit])"
}

/// "185 days 17 hours 29 minutes 26 seconds", rounded to the second, leaving out the units that
/// are zero; "0 seconds" for nothing.
func spokenDuration(_ seconds: Double) -> String {
    var left = Int(seconds.rounded())
    var parts: [String] = []
    for (noun, size) in [("day", 86_400), ("hour", 3_600), ("minute", 60), ("second", 1)] {
        let value = left / size
        left -= value * size
        if value > 0 { parts.append(count(value, noun)) }
    }
    return parts.isEmpty ? count(0, "second") : parts.joined(separator: " ")
}
