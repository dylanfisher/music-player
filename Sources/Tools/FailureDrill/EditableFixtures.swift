import Fixtures
import Foundation
import TagWriter

/// Up to two fixture files of each container the tag writer handles that it can edit and undo
/// byte for byte, tried on copies in the temp directory.
func editableFixtureFiles(in fixtures: URL) throws -> [String] {
    let manifest = try loadManifest(in: fixtures)
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("drill-tag-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: scratch)
        } catch {
            // Copies in the temp directory, which the system clears; worth a line, not a failure.
            print("couldn't remove \(scratch.path): \(error)", to: &standardError)
        }
    }
    let writer = TagWriter(journal: TagUndoJournal(dataDirectory: scratch))
    var picked: [String] = []
    for container in [FixtureFile.Container.flac, .mp4, .mp3] {
        let candidates = manifest.files.filter {
            $0.container == container && $0.malformation == nil
                && !$0.tagFormats.contains(.id3v22)
        }
        var kept = 0
        for file in candidates where kept < 2 {
            let original = fixtures.appendingPathComponent(file.path)
            let copy = scratch.appendingPathComponent(original.lastPathComponent)
            try FileManager.default.copyItem(at: original, to: copy)
            let written = writer.write(TagEdit(values: [.title: drillTitle]), to: [copy.path])
            let undone = writer.undoLast()
            if written.failures.isEmpty, undone.failures.isEmpty,
                try Data(contentsOf: copy) == Data(contentsOf: original)
            {
                picked.append(original.path)
                kept += 1
            }
            try FileManager.default.removeItem(at: copy)
        }
    }
    return picked
}
