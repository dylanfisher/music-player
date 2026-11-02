import Foundation
import Library

/// How many tracks, how many bytes and how long they play, as the status bar counts them.
struct TrackTotals: Equatable, Sendable {
    var count = 0
    var sizeBytes = 0
    var durationSeconds = 0.0

    init(_ tracks: some Sequence<ListedTrack>) {
        for track in tracks {
            count += 1
            sizeBytes += track.sizeBytes
            durationSeconds += track.durationSeconds
        }
    }

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
    while value >= 1024, unit < units.count - 1 {
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
