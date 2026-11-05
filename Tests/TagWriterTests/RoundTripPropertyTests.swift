import Foundation
import Testing

@testable import Fixtures
@testable import Metadata
@testable import TagWriter

private let alphabet = Array("ab Zé日本🎵-/'\"%_\\")

/// A value an editor could send for `field`: text, a number, or empty to clear it.
private func randomValue(_ field: TagEditField, _ random: inout SplitMix64) -> String {
    if random.chance(0.15) { return "" }
    if field.numberProperty != nil { return String(Int.random(in: 1...99, using: &random)) }
    switch field {
    case .compilation: return random.pick(["0", "1"])
    case .date, .originalDate: return String(Int.random(in: 1900...2030, using: &random))
    case .artistURL, .audioFileURL, .audioSourceURL, .commercialURL, .copyrightURL, .paymentURL,
        .publisherURL, .radioStationURL:
        // ID3's URL frames hold Latin-1 only.
        return "https://example.com/\(Int.random(in: 1...999, using: &random))"
    default:
        let length = Int.random(in: 1...40, using: &random)
        return String((0..<length).map { _ in random.pick(alphabet) })
    }
}

/// Random edits to a random generated file, then undoing them one by one: each write reads back,
/// one that fails leaves the file as it was, and each undo gives back the bytes from before its
/// edit, down to the original.
@Test func randomTagEditsUndoToTheOriginalBytes() throws {
    let (root, manifest) = try fixtureLibrary.get()
    let files = manifest.files.filter { $0.malformation == nil && $0.tags != nil }
    try forEachPropertyCase("tag edit round trips") { random in
        let original = try scratchCopy(of: root.appendingPathComponent(random.pick(files).path))
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let writer = scratchWriter()
        var snapshots = [try Data(contentsOf: original)]
        for step in 0..<Int.random(in: 1...5, using: &random) {
            var values: [TagEditField: String] = [:]
            for field in TagEditField.allCases where random.chance(0.3) {
                values[field] = randomValue(field, &random)
            }
            if values.isEmpty { values[.title] = randomValue(.title, &random) }
            let report = writer.write(TagEdit(values: values), to: [original.path])
            let bytes = try Data(contentsOf: original)
            if report.changed == [original.path] {
                snapshots.append(bytes)
                let read = try tags(original)
                for (field, keyPath) in [
                    (TagEditField.title, \TrackTags.title), (.artist, \.artist), (.album, \.album),
                ] {
                    guard let value = values[field] else { continue }
                    try #require(
                        read[keyPath: keyPath] == (value.isEmpty ? nil : value),
                        "step \(step): \(field) reads back from \(original.lastPathComponent)")
                }
            } else {
                try #require(
                    bytes == snapshots.last, "step \(step): a write that didn't change the file did"
                )
            }
        }
        for (step, expected) in snapshots.dropLast().enumerated().reversed() {
            let report = writer.undoLast()
            try #require(
                report.changed == [original.path] && report.failures.isEmpty,
                "undo to step \(step): \(report)")
            try #require(try Data(contentsOf: original) == expected, "undo to step \(step)")
        }
        try #require(writer.undoLast().nothingToUndo)
    }
}
