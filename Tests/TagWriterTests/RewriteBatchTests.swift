import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

/// A title too long for any fixture's padding, so the file is rewritten through its temp file.
private let longTitleEdit = TagEdit(values: [.title: String(repeating: "Long ", count: 20_000)])

/// The record of a rewrite carries the whole original's SHA-256, for undo, now taken from the
/// bytes the temp file was copied from (ADR 0196): it equals a hash of the original made apart
/// from the writer, whether the audio moved and was copied (a FLAC), or stayed and the temp file
/// is a clone (an AIFF whose ID3 chunk is its last).
@Test(arguments: [(Sample.flac, false), (.aiffV24, true)])
func theRecordedHashIsTheOriginals(_ sample: Sample, _ cloned: Bool) throws {
    let url = try sample.copy()
    let original = try Data(contentsOf: url)
    var writer = scratchWriter()
    let calls = FileCalls(&writer)
    expectChanged(writer.write(longTitleEdit, to: [url.path]), [url])
    let clones = calls.all.filter { if case .clone = $0 { true } else { false } }
    #expect(clones.isEmpty == !cloned, "the audio \(cloned ? "stayed" : "moved")")
    let (_, files, _) = try writer.journal.latest()
    let record = try #require(files.first).1
    #expect(record.originalSHA256 == Data(SHA256.hash(data: original)))
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}

/// A rewrite reads the original once, as it copies it, and the temp file once, to check it;
/// it no longer hashes the original in a pass of its own first (ADR 0196).
@Test func aRewriteReadsTheOriginalOnce() throws {
    let audioBytes = 16 * 1024 * 1024
    let url = try grownCopy(.flac, by: audioBytes)
    let size = try identity(url).size
    var writer = scratchWriter()
    let calls = FileCalls(&writer)
    expectChanged(writer.write(longTitleEdit, to: [url.path]), [url])
    #expect(calls.bytesRead < size * 5 / 2, "\(calls.bytesRead) bytes read of a \(size)")
}

/// A cover far larger than any fixture's padding, so every file it's saved to is rewritten.
private let coverEdit = TagEdit(art: .replace(pngImage(side: 400), mimeType: pngMIMEType))

/// Copies of a FLAC, each in a folder of its own.
private func flacs(_ count: Int) throws -> [URL] {
    try (0..<count).map { _ in try Sample.flac.copy() }
}

/// A batch mixing writes in place and rewrites, with a file that can't be read among them,
/// reports each file where the batch has it, though the first rewrite finishes last.
@Test func aMixedBatchReportsEachFileInItsPlace() throws {
    let urls = try flacs(8)
    let originals = try urls.map { try Data(contentsOf: $0) }
    let missing = urls[0].deletingLastPathComponent().appendingPathComponent("gone.flac")
    let slow = urls[1].path
    var writer = scratchWriter()
    writer.faults.beforeReplacing = { path, temp in
        if temp != nil, path == slow { Thread.sleep(forTimeInterval: 0.2) }
    }
    var edits = urls.enumerated().map { index, url in
        (
            path: url.path,
            edit: index % 2 == 0 ? TagEdit(values: [.title: "Track \(index)"]) : coverEdit
        )
    }
    edits.insert((path: missing.path, edit: coverEdit), at: 4)
    let report = writer.write(edits)
    #expect(report.changed == urls.map(\.path))
    #expect(report.failures.map(\.path) == [missing.path])
    #expect(report.notWritten == [])
    for (index, url) in urls.enumerated() {
        let parsed = try #require(report.parsed[url.path])
        #expect(parsed.parsed.metadata == (try readMetadata(at: url)).metadata)
        if index % 2 == 0 {
            #expect(try tags(url).title == "Track \(index)")
        } else {
            #expect(try art(url) == pngImage(side: 400))
        }
    }
    let undone = writer.undoLast()
    #expect(undone.failures == [])
    #expect(Set(undone.changed) == Set(urls.map(\.path)))
    #expect(try urls.map { try Data(contentsOf: $0) } == originals)
}

/// A batch rewrites `rewritesAtOnce` files at once, no more, and no fewer while it has as many
/// to write (ADR 0196).
@Test func aBatchRewritesSeveralFilesAtOnce() throws {
    let urls = try flacs(2 * rewritesAtOnce)
    var writer = scratchWriter()
    let inFlight = InFlight()
    writer.faults.beforeReplacing = { _, _ in
        inFlight.enter()
        // Each waits for the rest to arrive, so a loaded Mac's slow reads don't hide them.
        let deadline = Date(timeIntervalSinceNow: 2)
        while inFlight.current < rewritesAtOnce, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.05)
        inFlight.leave()
    }
    expectChanged(writer.write(coverEdit, to: urls.map(\.path)), urls)
    #expect(inFlight.most == rewritesAtOnce, "\(inFlight.most) of \(rewritesAtOnce)")
    for url in urls { #expect(try art(url) == pngImage(side: 400)) }
}

/// The faults a rewrite can meet once its temp file is written, each injected into every file
/// of a batch with several in flight.
enum RewriteFault: CaseIterable, Sendable {
    /// The temp file fails as it closes.
    case tempCloses
    /// The write fails before the rename.
    case beforeRename
    /// It stops right before the rename, as a crash would.
    case crash
}

/// Each fault with several rewrites in flight leaves every original as it was, and the next
/// write and undo find what one rewrite's fault leaves (ADR 0196): after a failure, no temp
/// file and nothing to undo; after a crash, a temp file each, which the next write removes,
/// and records that no longer match their files, which undo drops.
@Test(arguments: RewriteFault.allCases)
func aFaultInEachOfSeveralRewritesLeavesTheOriginals(_ fault: RewriteFault) throws {
    let urls = try flacs(2 * rewritesAtOnce)
    let originals = try urls.map { try Data(contentsOf: $0) }
    var writer = scratchWriter()
    let inFlight = InFlight()
    let overlap: @Sendable () -> Void = {
        inFlight.enter()
        Thread.sleep(forTimeInterval: 0.05)
        inFlight.leave()
    }
    switch fault {
    case .tempCloses:
        writer.faults.whenTempCloses = { _ in
            overlap()
            throw POSIXError(.EIO)
        }
    case .beforeRename:
        writer.faults.beforeReplacing = { _, _ in
            overlap()
            throw POSIXError(.EIO)
        }
    case .crash:
        writer.faults.beforeReplacing = { _, _ in overlap() }
        writer.faults.crashBeforeRename = true
    }
    let report = writer.write(coverEdit, to: urls.map(\.path))
    #expect(inFlight.most > 1, "several in flight")
    #expect(report.changed == [])
    #expect(report.failures.map(\.path) == urls.map(\.path))
    #expect(try urls.map { try Data(contentsOf: $0) } == originals)

    let next = TagWriter(journal: writer.journal)
    #expect(next.recoverInterrupted().failures == [])
    for url in urls {
        #expect(try leftoverTemps(for: url.path).count == (fault == .crash ? 1 : 0))
    }
    let undone = next.undoLast()
    if fault == .crash {
        #expect(undone.failures.map(\.kind) == urls.map { _ in .changedSinceEdit })
    } else {
        #expect(undone.nothingToUndo)
    }
    expectChanged(next.write(coverEdit, to: urls.map(\.path)), urls)
    for url in urls { #expect(try leftoverTemps(for: url.path).isEmpty) }
}

/// A full disk in one rewrite stops the batch: no new file starts, those in flight finish,
/// and it leaves no temp file and no record without the file it was written for, so undo puts
/// back exactly the files written.
@Test func aFullDiskInARewriteStopsTheBatch() throws {
    let urls = try flacs(3 * rewritesAtOnce)
    let originals = try urls.map { try Data(contentsOf: $0) }
    let full = urls[1].path
    var writer = scratchWriter()
    writer.faults.beforeReplacing = { path, _ in
        Thread.sleep(forTimeInterval: 0.05)
        if path == full {
            throw TagWriteError(path: path, kind: .diskFull, detail: "the disk is full")
        }
    }
    let report = writer.write(coverEdit, to: urls.map(\.path))
    #expect(report.failures.map(\.kind) == [.diskFull])
    #expect(!report.notWritten.isEmpty)
    #expect(report.notWritten == Array(urls.map(\.path).suffix(report.notWritten.count)))
    #expect(
        Set(report.changed + [full] + report.notWritten) == Set(urls.map(\.path)),
        "every file written, failed or not started")
    for url in urls { #expect(try leftoverTemps(for: url.path).isEmpty) }
    for path in report.notWritten {
        let index = try #require(urls.firstIndex { $0.path == path })
        #expect(try Data(contentsOf: urls[index]) == originals[index])
    }

    let undone = writer.undoLast()
    #expect(undone.failures == [])
    #expect(Set(undone.changed) == Set(report.changed))
    #expect(try urls.map { try Data(contentsOf: $0) } == originals)
}
