import Foundation
import TagWriter

/// A batch edit's journal: what a 1000-track album-art change costs before any music file is
/// replaced, each record flushed to the disk as the writer does.
let tagWriterBenchmarks = [
    Benchmark(
        name: "tag journal: write a 1000-file batch with 1 MB art each",
        budget: Budget(appleSilicon: 20, oldMac: 60, unit: .seconds)
    ) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/bench-tag-journal")
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let journal = TagUndoJournal(dataDirectory: root)
        let art = [UInt8](repeating: 0xA5, count: 1024 * 1024)
        let elapsed = try seconds {
            let entry = try journal.newEntry()
            for index in 0..<1000 {
                let record = TagUndoJournal.FileRecord(
                    path: "/Music/Album/\(index).m4a", editedSize: 50_000_000,
                    editedModifiedNanoseconds: index, editedInode: UInt64(index),
                    originalSize: 50_000_000, originalModifiedNanoseconds: index,
                    originalInode: UInt64(index),
                    originalSHA256: Data(count: 32),
                    restore: [
                        .old(length: art.count),
                        .edited(lowerBound: 0, upperBound: 49_000_000),
                    ])
                _ = try journal.append(record, oldBytes: [art], to: entry)
            }
        }
        try FileManager.default.removeItem(at: root)
        return Measured(value: elapsed)
    }
]
