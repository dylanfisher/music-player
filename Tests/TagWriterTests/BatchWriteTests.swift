import Darwin
import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

private let titleEdit = TagEdit(values: [.title: "Edited"])

/// One file of each container whose tags have room for the title, each in a folder of its own.
private func batch() throws -> [URL] {
    try [Sample.flac, .mp4, .mp3v23, .mp3v24, .aiffV24, .wavID3].map(paddedCopy)
}

/// A batch stopped after each step of its writes in place, as a crash there would: the next
/// call leaves every file as it was or as edited, never torn, with nothing unconfirmed, and
/// undo puts every edited file back (ADR 0108).
@Test(arguments: BatchStep.allCases)
func aBatchCrashedAfterEachStepIsPutRight(_ step: BatchStep) throws {
    let urls = try batch()
    let originals = try urls.map { try Data(contentsOf: $0) }
    var crashing = scratchWriter()
    crashing.faults.crashAfter = step
    let crashed = crashing.write(titleEdit, to: urls.map(\.path))
    #expect(crashed.changed.isEmpty, "\(step)")

    let writer = TagWriter(journal: crashing.journal)
    let recovered = writer.recoverInterrupted()
    #expect(recovered.failures == [], "\(step)")
    #expect(recovered.changed == [], "nothing was torn: \(step)")
    #expect(try markers(writer).isEmpty, "\(step)")
    let edited = try urls.map { try tags($0).title == "Edited" }
    let expected: [Bool] =
        switch step {
        case .journaled: urls.map { _ in false }
        case .firstWritten: urls.indices.map { $0 == 0 }
        case .written, .flushed, .firstConfirmed: urls.map { _ in true }
        }
    #expect(edited == expected, "\(step)")
    for (url, original) in zip(urls, originals) where try tags(url).title != "Edited" {
        #expect(try Data(contentsOf: url) == original, "\(step): \(url.lastPathComponent)")
    }

    let undone = writer.undoLast()
    #expect(undone.failures == [], "\(step)")
    #expect(Set(undone.changed) == Set(zip(urls, edited).filter(\.1).map(\.0.path)), "\(step)")
    #expect(try urls.map { try Data(contentsOf: $0) } == originals, "\(step)")
    for url in urls { #expect(try leftoverTemps(for: url.path).isEmpty, "\(step)") }
}

/// A crash part way through every write of a batch: each file is put back from the journal.
@Test func aBatchTornByACrashIsPutBack() throws {
    let urls = try batch()
    let originals = try urls.map { try Data(contentsOf: $0) }
    var crashing = scratchWriter()
    crashing.faults.tornWriteBytes = 1
    _ = crashing.write(titleEdit, to: urls.map(\.path))
    #expect(try urls.map { try Data(contentsOf: $0) } != originals, "torn")

    let writer = TagWriter(journal: crashing.journal)
    expectChanged(writer.recoverInterrupted(), urls)
    #expect(try urls.map { try Data(contentsOf: $0) } == originals)
    #expect(try markers(writer).isEmpty)
    #expect(writer.undoLast().nothingToUndo)
}

/// A batch in place flushes the drive's cache twice, however many files it writes: once for
/// the journal before the first write, once for the music files after the last (ADR 0108).
@Test func aBatchInPlaceFlushesTheDriveTwice() throws {
    let urls = try batch()
    var journal = TagUndoJournal(dataDirectory: scratchFolder())
    let journalFlushes = FlushCount()
    journal.driveFlushed = { journalFlushes.add() }
    var writer = TagWriter(journal: journal)
    let calls = FileCalls(&writer)
    expectChanged(writer.write(titleEdit, to: urls.map(\.path)), urls)
    #expect(journalFlushes.count == 1)
    #expect(calls.all.filter { $0 == .flushDrive }.count == 1, "one volume")
    #expect(calls.all.filter { $0 == .flush }.count == urls.count, "each write's fsync")
}

private final class FlushCount: @unchecked Sendable {
    // `value` is guarded by `lock`.
    private let lock = NSLock()
    private var value = 0

    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
