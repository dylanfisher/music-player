import Fixtures
import Foundation
import TagEditor

/// Files the tag editor opens on, as when an artist's albums are selected.
private let editedFileCount = 200
/// The files the editor opens for one track: the tags, the art and the fields holding several
/// values are each read from a fresh open.
private let opensPerEditedFile = 3

let tagEditorBenchmarks = [
    Benchmark(
        name: "tag editor: read \(editedFileCount) fixture files on the slow simulated NAS",
        budget: Budget(appleSilicon: 5, oldMac: 15, unit: .seconds)
    ) {
        let root = try defaultFixturesDirectory()
        _ = try generateFixtures(count: fullLibraryFileCount, in: root)
        let paths = try loadManifest(in: root).files.prefix(editedFileCount).map {
            root.appendingPathComponent($0.path).path
        }
        var read: (tracks: [EditableTrack], problems: [String])?
        let elapsed = seconds {
            read = readEditableTracks(paths) { path in
                // Each open costs what an art read does on the slow NAS (ADR 0073).
                Thread.sleep(forTimeInterval: Double(opensPerEditedFile) * nasArtReadSeconds)
                return try readEditableTrack(path)
            }
        }
        guard let read, !read.tracks.isEmpty else { throw BenchError.expected("tracks read") }
        return Measured(
            value: elapsed,
            notes: [
                "\(read.tracks.count) read, \(read.problems.count) the editor can't open;"
                    + String(
                        format: " %.0f ms a file's opens on the NAS",
                        Double(opensPerEditedFile) * nasArtReadSeconds * 1000)
            ])
    }
]
