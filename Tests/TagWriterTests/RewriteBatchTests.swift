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
