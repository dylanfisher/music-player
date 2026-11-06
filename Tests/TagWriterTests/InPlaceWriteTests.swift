import Darwin
import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

private let titleEdit = TagEdit(values: [.title: "Edited"])

/// A copy of `sample` whose tags have padding a short title fits in. The generated MP4s have no
/// `free` atom, so one gets a longer title first, which the writer rewrites with padding.
private func paddedCopy(_ sample: Sample) throws -> URL {
    let url = try sample.copy()
    guard sample == .mp4 || sample == .mp4WithArt else { return url }
    let longer = TagEdit(values: [.title: String(repeating: "Longer title ", count: 4)])
    expectChanged(scratchWriter().write(longer, to: [url.path]), [url])
    return url
}

private let paddedSamples: [Sample] = [
    .flac, .flacWithArt, .mp4, .mp4WithArt, .mp3v23, .mp3v24, .mp3v24WithArt, .aiffV24, .wavID3,
]

@Test(arguments: paddedSamples)
func aTagThatFitsIsWrittenInPlace(_ sample: Sample) throws {
    let url = try paddedCopy(sample)
    let original = try Data(contentsOf: url)
    let payload = try readTagLayout(at: url).payload
    let before = try identity(url)
    let writer = scratchWriter()
    expectChanged(writer.write(titleEdit, to: [url.path]), [url])
    #expect(try tags(url).title == "Edited")
    let edited = try Data(contentsOf: url)
    let after = try identity(url)
    #expect(after.inode == before.inode && after.device == before.device, "the same file")
    #expect(edited.count == original.count)
    let changed = original.indices.filter { original[$0] != edited[$0] }
    #expect(!changed.isEmpty)
    #expect(changed.allSatisfy { offset in !payload.contains { $0.contains(offset) } })
    for range in payload { #expect(edited[range] == original[range], "the audio is unchanged") }
    #expect(try leftoverTemps(for: url.path).isEmpty)
    #expect(try markers(writer).isEmpty)
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}

@Test(arguments: [Sample.flac, .mp4, .mp3v24, .aiffV24])
func aTagPastThePaddingGoesThroughATempFile(_ sample: Sample) throws {
    let url = try sample.copy()
    let original = try Data(contentsOf: url)
    let before = try identity(url)
    let writer = scratchWriter()
    let long = String(repeating: "Long ", count: 20_000)
    expectChanged(writer.write(TagEdit(values: [.title: long]), to: [url.path]), [url])
    #expect(try tags(url).title == long)
    #expect(try identity(url).inode != before.inode, "renamed over")
    #expect(try markers(writer).isEmpty)
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}

/// The audio a write in place never touches isn't read, before or after (ADR 0108): a long
/// track costs what a short one does.
@Test(arguments: [Sample.flac, .flacWithArt, .mp3v24])
func aWriteInPlaceReadsOnlyAroundTheTag(_ sample: Sample) throws {
    let audioBytes = 16 * 1024 * 1024
    let url = try grownCopy(sample, by: audioBytes)
    var writer = scratchWriter()
    let calls = FileCalls(&writer)
    let before = try identity(url)
    expectChanged(writer.write(titleEdit, to: [url.path]), [url])
    #expect(try identity(url).inode == before.inode, "written in place")
    #expect(try tags(url).title == "Edited")
    #expect(calls.bytesRead < audioBytes / 8, "\(calls.bytesRead) bytes read")
}

/// The record keeps the region's offset and its old and new bytes' hashes, not the whole
/// file's; recovery reads only the region to tell a torn write from one that landed.
@Test func aWriteInPlaceIsJournaledAndRecoveredByItsRegion() throws {
    let audioBytes = 16 * 1024 * 1024
    let url = try grownCopy(.flac, by: audioBytes)
    let original = try Data(contentsOf: url)
    var crashing = scratchWriter()
    crashing.faults.tornWriteBytes = 1
    _ = crashing.write(titleEdit, to: [url.path])
    let entry = try #require(
        try FileManager.default.contentsOfDirectory(atPath: crashing.journal.directory.path)
            .filter { !$0.contains(".") }.sorted().last)
    let json = try #require(
        try JSONSerialization.jsonObject(
            with: Data(
                contentsOf: crashing.journal.directory.appendingPathComponent(entry)
                    .appendingPathComponent("00000001.json"))) as? [String: Any])
    #expect(json["originalSHA256"] == nil)
    let region = try #require(json["inPlace"] as? [String: Any])
    #expect(Set(region.keys) == ["offset", "oldSHA256", "newLength", "newSHA256"])

    var writer = TagWriter(journal: crashing.journal)
    let calls = FileCalls(&writer)
    expectChanged(writer.recoverInterrupted(), [url])
    #expect(try Data(contentsOf: url) == original)
    let reads = calls.all.filter { if case .read = $0 { true } else { false } }
    // The region, then the restored temp file's region; the copy into the temp file is an
    // APFS clone here.
    #expect(calls.bytesRead < audioBytes / 8, "\(calls.bytesRead) bytes in \(reads.count) reads")
}

/// A save past the padding leaves room for the next edits (ADR 0108): 64 KiB, or as much again
/// as the tag when that's more, so 30 KB of lyrics, or a cover as big as the one there, is then
/// written in place.
@Test(arguments: [Sample.flac, .flacWithArt, .mp4, .mp4WithArt, .mp3v24, .mp3v24WithArt, .aiffV24])
func aSaveThroughTheTempFileLeavesRoomForTheNext(_ sample: Sample) throws {
    let url = try sample.copy()
    let writer = scratchWriter()
    let long = String(repeating: "Long ", count: try readTagLayout(at: url).paddingBytes / 5 + 100)
    expectChanged(writer.write(TagEdit(values: [.title: long]), to: [url.path]), [url])
    let layout = try readTagLayout(at: url)
    let tagBytes = layout.blocks.filter { [.field, .art].contains($0.kind) }
        .reduce(0) { $0 + $1.range.count }
    #expect(layout.paddingBytes >= max(64 * 1024, tagBytes) - 8, "\(layout.paddingBytes)")

    let before = try identity(url)
    let lyrics = TagEdit(values: [.lyrics: String(repeating: "La la ", count: 5_000)])
    expectChanged(writer.write(lyrics, to: [url.path]), [url])
    #expect(try identity(url).inode == before.inode, "the lyrics written in place")
    if let image = try art(url) {
        let before = try identity(url)
        let cover = TagEdit(
            art: .replace(
                pngImage(side: Int(Double(image.count).squareRoot())), mimeType: pngMIMEType))
        expectChanged(writer.write(cover, to: [url.path]), [url])
        #expect(try identity(url).inode == before.inode, "a cover as big written in place")
    }
}

/// An MP4 with `moov` last grows in place past its old end (ADR 0108): the same file, the audio
/// and every byte before the edit where they were, and undo cuts it back to the original.
@Test func anMP4WithMoovLastGrowsInPlace() throws {
    let url = try mp4WithMoovLast()
    let original = try Data(contentsOf: url)
    let payload = try readTagLayout(at: url).payload
    let before = try identity(url)
    let writer = scratchWriter()
    let long = TagEdit(values: [.title: String(repeating: "Grown ", count: 200)])
    expectChanged(writer.write(long, to: [url.path]), [url])
    #expect(try identity(url).inode == before.inode, "written in place")
    let grown = try Data(contentsOf: url)
    #expect(grown.count > original.count)
    let moov = try #require(try readTagLayout(at: url).blocks.first { $0.path == "moov" })
    #expect(grown[..<moov.range.lowerBound] == original[..<moov.range.lowerBound])
    #expect(try readTagLayout(at: url).payload == payload)
    #expect(try tags(url).title == long.values[.title])
    // The rewrite left room, so the next edit keeps the size.
    expectChanged(writer.write(titleEdit, to: [url.path]), [url])
    #expect(try Data(contentsOf: url).count == grown.count)
    expectChanged(writer.undoLast(), [url])
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}

/// A crash part way through a write that grows the file, and one after it landed: recovery
/// cuts a torn one back to the original and keeps one that landed.
@Test(arguments: [1, 9, Int.max])
func anMP4GrowingInPlaceCutShortIsPutRight(_ bytes: Int) throws {
    let url = try mp4WithMoovLast()
    let original = try Data(contentsOf: url)
    let long = TagEdit(values: [.title: String(repeating: "Grown ", count: 200)])
    var crashing = scratchWriter()
    crashing.faults.tornWriteBytes = bytes
    _ = crashing.write(long, to: [url.path])

    let writer = TagWriter(journal: crashing.journal)
    let report = writer.recoverInterrupted()
    #expect(report.failures == [])
    #expect(try markers(writer).isEmpty)
    if bytes == Int.max {
        #expect(report.changed == [])
        #expect(try tags(url).title == long.values[.title])
        expectChanged(writer.undoLast(), [url])
    } else {
        #expect(report.changed == [url.path])
    }
    #expect(try Data(contentsOf: url) == original)
}

/// A crash part way through the one write leaves the tag torn; the next call puts the original
/// back from the journal, byte for byte, and there is nothing left to undo.
@Test(arguments: [Sample.flac, .mp4, .mp3v24, .aiffV24, .wavID3])
func aWriteInPlaceTornByACrashIsPutBack(_ sample: Sample) throws {
    let url = try paddedCopy(sample)
    let original = try Data(contentsOf: url)
    var crashing = scratchWriter()
    crashing.faults.tornWriteBytes = 1
    let crashed = crashing.write(titleEdit, to: [url.path])
    #expect(crashed.changed.isEmpty)
    #expect(try Data(contentsOf: url) != original, "torn")
    #expect(try markers(crashing).count == 1)

    let writer = TagWriter(journal: crashing.journal)
    let report = writer.recoverInterrupted()
    expectChanged(report, [url])
    #expect(try Data(contentsOf: url) == original)
    #expect(try markers(writer).isEmpty)
    #expect(try leftoverTemps(for: url.path).isEmpty)
    #expect(writer.undoLast().nothingToUndo)
}

/// The whole tag written, then a crash before the read-back confirmed it: recovery finds the
/// file as the write meant it and keeps the edit, which undoes as usual.
@Test func aWriteInPlaceThatLandedBeforeACrashIsKept() throws {
    let url = try Sample.mp3v24.copy()
    let original = try Data(contentsOf: url)
    var crashing = scratchWriter()
    crashing.faults.tornWriteBytes = Int.max
    _ = crashing.write(titleEdit, to: [url.path])
    #expect(try tags(url).title == "Edited")

    let writer = TagWriter(journal: crashing.journal)
    let report = writer.recoverInterrupted()
    #expect(report.failures == [])
    #expect(report.changed == [])
    #expect(try tags(url).title == "Edited")
    #expect(try markers(writer).isEmpty)
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}

/// A crash after the journal and before the write: undo finds the file still the original and
/// drops the record.
@Test func aCrashBeforeTheWriteInPlaceLeavesTheOriginal() throws {
    let url = try Sample.flac.copy()
    let original = try Data(contentsOf: url)
    var crashing = scratchWriter()
    crashing.faults.tornWriteBytes = 0
    _ = crashing.write(titleEdit, to: [url.path])
    #expect(try Data(contentsOf: url) == original)

    let writer = TagWriter(journal: crashing.journal)
    let report = writer.undoLast()
    #expect(report.failures == [])
    #expect(report.nothingToUndo)
    #expect(try Data(contentsOf: url) == original)
    #expect(try markers(writer).isEmpty)
}

/// Another app changes the title's bytes after the file is read, keeping its size and mtime:
/// the write in place finds bytes it didn't read and is refused, leaving the other app's
/// change. A changed mtime is refused too.
@Test(arguments: ["a byte, same mtime", "the mtime"])
func aFileChangedUnderneathIsNotWrittenInPlace(_ change: String) throws {
    let url = try Sample.flac.copy()
    let title = try #require(try tags(url).title)
    var writer = scratchWriter()
    writer.faults.beforeReplacing = { path, temp in
        guard temp == nil else { throw POSIXError(.EINVAL) }
        if change == "the mtime" {
            guard utimes(path, nil) == 0 else { throw POSIXError(.EIO) }
            return
        }
        var info = stat()
        guard stat(path, &info) == 0 else { throw POSIXError(.EIO) }
        try scribble(on: title, in: path)
        var times = [info.st_atimespec, info.st_mtimespec]
        guard utimensat(AT_FDCWD, path, &times, 0) == 0 else { throw POSIXError(.EIO) }
    }
    let report = writer.write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.changedDuringWrite], "\(change)")
    #expect(try tags(url).title != "Edited", "\(change)")
    if change != "the mtime" { #expect(try tags(url).title != title, "the other app's edit") }
    #expect(try markers(writer).isEmpty, "\(change)")
    #expect(writer.undoLast().nothingToUndo, "\(change)")
}

/// The file reads back wrong after the write, as a server that stored other bytes would: the
/// original is put back from the journal and the write fails.
@Test(arguments: [Sample.flac, .mp4, .mp3v24])
func aWriteInPlaceThatDoesntReadBackPutsTheOriginalBack(_ sample: Sample) throws {
    let url = try paddedCopy(sample)
    let original = try Data(contentsOf: url)
    var writer = scratchWriter()
    writer.faults.afterOverwriting = { path in try scribble(on: "Edited", in: path) }
    let report = writer.write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.checkFailed])
    #expect(report.changed.isEmpty)
    #expect(try Data(contentsOf: url) == original)
    #expect(try markers(writer).isEmpty)
    #expect(try leftoverTemps(for: url.path).isEmpty)
    #expect(writer.undoLast().nothingToUndo)
}

/// A WAV's LIST/INFO fills in an album its ID3 chunk no longer has, so clearing it can't read
/// back; the check on the planned file refuses it before the original is opened for writing.
@Test func aWriteInPlaceThatWouldntReadBackIsRefusedBeforeWriting() throws {
    let url = try Sample.wavInfoAndID3.copy()
    let original = try Data(contentsOf: url)
    let before = try identity(url)
    let writer = scratchWriter()
    let report = writer.write(TagEdit(values: [.album: ""]), to: [url.path])
    #expect(report.failures.map(\.kind) == [.checkFailed])
    #expect(try Data(contentsOf: url) == original)
    #expect(try identity(url) == before, "not even the mtime moved")
    #expect(writer.undoLast().nothingToUndo)
}

/// The read-back fails and the folder refuses the temp file that would put the original back:
/// the journal keeps the write, and a later call puts the original back once it can.
@Test func aWriteInPlaceThatCantBePutBackAtOnceIsPutBackLater() throws {
    let url = try Sample.mp3v24.copy()
    let original = try Data(contentsOf: url)
    let folder = url.deletingLastPathComponent().path
    var writer = scratchWriter()
    writer.faults.afterOverwriting = { path in
        try scribble(on: "Edited", in: path)
        guard chmod(folder, 0o500) == 0 else { throw POSIXError(.EIO) }
    }
    let report = writer.write(titleEdit, to: [url.path])
    chmod(folder, 0o700)
    #expect(report.failures.map(\.kind) == [.checkFailed])
    #expect(try Data(contentsOf: url) != original)
    #expect(try markers(writer).count == 1)
    expectChanged(TagWriter(journal: writer.journal).recoverInterrupted(), [url])
    #expect(try Data(contentsOf: url) == original)
    #expect(try markers(writer).isEmpty)
}

@Test func aMarkerWhoseRecordIsGoneIsRemoved() throws {
    let writer = scratchWriter()
    let entry = try writer.journal.newEntry()
    let marker = TagUndoJournal.Handle(entry: entry, number: 1).marker
    #expect(FileManager.default.createFile(atPath: marker.path, contents: nil))
    #expect(writer.recoverInterrupted() == TagWriteReport())
    #expect(try markers(writer).isEmpty)
}

/// Replaces the middle byte of the first `text` in the file at `path` with an X.
private func scribble(on text: String, in path: String) throws {
    let url = URL(fileURLWithPath: path)
    var data = try Data(contentsOf: url)
    let range = try #require(data.range(of: Data(text.utf8)))
    data[range.lowerBound + range.count / 2] = UInt8(ascii: "X")
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: data)
    try handle.close()
}

private func identity(_ url: URL) throws -> FileIdentity { try FileIdentity(path: url.path) }

/// The journal's markers of unconfirmed writes in place.
private func markers(_ writer: TagWriter) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: writer.journal.directory.path).filter {
        $0.hasSuffix(TagUndoJournal.unconfirmedSuffix)
    }
}
