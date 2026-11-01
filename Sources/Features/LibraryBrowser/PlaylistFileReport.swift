import Foundation
import Library

extension PlaylistImport {
    /// "Imported “Mix”: 40 tracks · 3 not in the library · 1 listed twice · 2 lines skipped".
    var summary: String {
        var parts = ["Imported “\(name)”: \(count(added, "track"))"]
        if !missing.isEmpty { parts.append("\(number(missing.count)) not in the library") }
        if repeated > 0 { parts.append("\(number(repeated)) listed twice") }
        let skipped = file.problems.count + file.unlistedProblemCount
        if skipped > 0 { parts.append("\(count(skipped, "line")) skipped") }
        return parts.joined(separator: " · ")
    }

    /// The summary, then each entry not in the library and each skipped line, the first
    /// `PlaylistFile.maximumProblems` of each and then a count. Empty when every entry was added.
    var reportLines: [String] {
        guard !missing.isEmpty || repeated > 0 || !file.problems.isEmpty else { return [] }
        let shown = PlaylistFile.maximumProblems
        var lines = ["\(source): \(summary)"]
        lines += missing.prefix(shown).map { "\(source): not in the library: \($0)" }
        if missing.count > shown {
            lines.append("\(source): \(number(missing.count - shown)) more not in the library")
        }
        lines += file.problems.map { "\(source): \($0)" }
        if file.unlistedProblemCount > 0 {
            lines.append("\(source): \(count(file.unlistedProblemCount, "more line")) skipped")
        }
        return lines
    }
}

/// "Exported 40 tracks to Mix.m3u8 · 3 not in the library · 1 not written", and a
/// line for each path that couldn't be written, the first `PlaylistFile.maximumProblems`.
func exportReport(
    file: String, written: Int, missing: Int, unwritable: [String]
) -> (summary: String, lines: [String]) {
    var parts = ["Exported \(count(written, "track")) to \((file as NSString).lastPathComponent)"]
    if missing > 0 { parts.append("\(number(missing)) not in the library") }
    if !unwritable.isEmpty {
        parts.append("\(number(unwritable.count)) not written")
    }
    let summary = parts.joined(separator: " · ")
    guard !unwritable.isEmpty else { return (summary, []) }
    let shown = PlaylistFile.maximumProblems
    var lines = ["\(file): \(summary)"]
    lines += unwritable.prefix(shown).map {
        "\(file): not written, since a line can't hold its path: \($0.debugDescription)"
    }
    if unwritable.count > shown {
        lines.append("\(file): \(number(unwritable.count - shown)) more not written")
    }
    return (summary, lines)
}
