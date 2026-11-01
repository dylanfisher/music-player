import Darwin
import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

/// The newest edit's folder in `journal`.
private func newestEntry(_ journal: TagUndoJournal) throws -> URL {
    let names = try FileManager.default.contentsOfDirectory(atPath: journal.directory.path).sorted()
    return journal.directory.appendingPathComponent(try #require(names.last))
}

@Test func aRecordWithAnUnknownKeyAnywhereIsDiscardedAndReported() throws {
    let url = try Sample.mp3v24.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    expectChanged(writer.write(TagEdit(values: [.title: "Two"]), to: [url.path]), [url])
    let record = try newestEntry(writer.journal).appendingPathComponent("00000001.json")
    var json = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
    var segments = try #require(json["restore"] as? [[String: Any]])
    segments[0]["extra"] = true
    json["restore"] = segments
    try JSONSerialization.data(withJSONObject: json).write(to: record)

    let report = writer.undoLast()
    #expect(report.failures.map(\.kind) == [.journal, .changedSinceEdit])
    #expect(!FileManager.default.fileExists(atPath: record.path))
}

@Test func aRecordWhoseBytesDontMatchIsDiscarded() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    let bytes = try newestEntry(writer.journal).appendingPathComponent("00000001.bytes")
    try Data([1, 2, 3]).write(to: bytes)
    #expect(writer.undoLast().failures.map(\.kind) == [.journal])
    #expect(writer.undoLast().nothingToUndo)
}

@Test func theJournalKeepsTheNewestEdits() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    for index in 0...TagUndoJournal.capacity {
        expectChanged(
            writer.write(TagEdit(values: [.title: "Take \(index)"]), to: [url.path]), [url])
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: writer.journal.directory.path)
    #expect(names.sorted().first == "00000002")
    #expect(names.count == TagUndoJournal.capacity)
}

@Test func theJournalIsCappedByBytesButKeepsTheNewestEdit() throws {
    let url = try Sample.mp4WithArt.copy()
    let writer = TagWriter(
        journal: TagUndoJournal(dataDirectory: scratchFolder(), capacityBytes: 1000))
    for index in 0..<3 {
        let edit = TagEdit(art: .replace(pngImage(side: 40 + index), mimeType: pngMIMEType))
        expectChanged(writer.write(edit, to: [url.path]), [url])
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: writer.journal.directory.path)
    #expect(names == ["00000003"])
    expectChanged(writer.undoLast(), [url])
}

@Test func aJournalThatCantBeWrittenStopsTheBatchAfterThatFile() throws {
    let urls = try [Sample.mp4, .mp3v24, .flac].map { try $0.copy() }
    var writer = scratchWriter()
    let journal = writer.journal
    writer.faults.beforeReplacing = { _, _ in
        // Once the first file is journaled, its edit's folder becomes read-only.
        let folder = try newestEntry(journal)
        chmod(folder.path, 0o500)
    }
    let originals = try urls.dropFirst().map { try Data(contentsOf: $0) }
    let report = writer.write(TagEdit(values: [.album: "Stopped"]), to: urls.map(\.path))
    chmod(try newestEntry(journal).path, 0o700)
    #expect(report.changed == [urls[0].path])
    #expect(report.failures.map(\.kind) == [.journal])
    #expect(report.failures.map(\.path) != [])
    #expect(report.notWritten == [urls[2].path])
    #expect(try urls.dropFirst().map { try Data(contentsOf: $0) } == originals)
}

@Test func undoComparesTheInodeToo() throws {
    let url = try Sample.mp3v24.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "Edited"]), to: [url.path]), [url])
    // The same bytes, size and mtime, in a new file: another app saved over it.
    let copy = url.path + ".copy"
    #expect(clonefile(url.path, copy, 0) == 0)
    #expect(rename(copy, url.path) == 0)
    #expect(writer.undoLast().failures.map(\.kind) == [.changedSinceEdit])
}

@Test func editsOfOneFileUndoOneAfterAnother() throws {
    let url = try Sample.flac.copy()
    let original = try Data(contentsOf: url)
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    let afterOne = try Data(contentsOf: url)
    expectChanged(writer.write(TagEdit(values: [.title: "Two"]), to: [url.path]), [url])
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == afterOne)
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
    #expect(writer.undoLast().nothingToUndo)
}

@Test func anOlderEditOfAFileChangedInBetweenStillRefusesToUndo() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    // Another app saves over the file between the two edits.
    let copy = url.path + ".copy"
    #expect(clonefile(url.path, copy, 0) == 0)
    #expect(rename(copy, url.path) == 0)
    expectChanged(writer.write(TagEdit(values: [.title: "Two"]), to: [url.path]), [url])
    expectChanged(writer.undoLast(), [url])
    #expect(writer.undoLast().failures.map(\.kind) == [.changedSinceEdit])
}

@Test func aFileSavedOverAfterTheFirstUndoRefusesTheSecond() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    expectChanged(writer.write(TagEdit(values: [.title: "Two"]), to: [url.path]), [url])
    expectChanged(writer.undoLast(), [url])
    // Another app saves the same bytes as a new file.
    let copy = url.path + ".copy"
    #expect(clonefile(url.path, copy, 0) == 0)
    #expect(rename(copy, url.path) == 0)
    let saved = try Data(contentsOf: url)
    #expect(writer.undoLast().failures.map(\.kind) == [.changedSinceEdit])
    #expect(try Data(contentsOf: url) == saved)
}

/// The file is put back even when the older edit's record can't be brought up to date; the
/// report says it changed and nothing else, and that edit refuses later.
@Test func anUndoWhoseOlderRecordCantBeUpdatedReportsOnlyTheChange() throws {
    let url = try Sample.flac.copy()
    let journal = TagUndoJournal(dataDirectory: scratchFolder())
    let writer = TagWriter(journal: journal)
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    let older = try newestEntry(journal)
    expectChanged(writer.write(TagEdit(values: [.title: "Two"]), to: [url.path]), [url])
    #expect(chmod(older.path, 0o555) == 0)
    defer { chmod(older.path, 0o755) }
    let report = writer.undoLast()
    #expect(report.changed == [url.path])
    #expect(report.failures.isEmpty)
    chmod(older.path, 0o755)
    #expect(writer.undoLast().failures.map(\.kind) == [.changedSinceEdit])
}

@Test func editValuesAreChecked() throws {
    var tags = TrackTags()
    tags.title = "Old"
    tags.trackNumber = 3
    let edit = TagEdit(values: [.title: "", .trackTotal: "12", .compilation: "1"])
    let result = try edit.applied(to: tags)
    #expect(result.title == nil)
    #expect(result.trackNumber == 3)
    #expect(result.trackTotal == 12)
    #expect(result.compilation)
    #expect(throws: TagValueError.self) {
        try TagEdit(values: [.trackNumber: "0"]).applied(to: tags)
    }
}

/// Each group's keys are the reader's, so what the writer removes is all the reader reads.
@Test func everyGroupHasKeysInEveryFormat() {
    for group in TagGroup.allCases {
        let fields = group.readerFields
        #expect(!fields.flatMap { id3FrameIDs(for: $0) }.isEmpty, "\(group) in ID3")
        #expect(!fields.flatMap { mp4ItemTypes(for: $0) }.isEmpty, "\(group) in MP4")
        #expect(!fields.flatMap { vorbisKeys(for: $0) }.isEmpty, "\(group) in Vorbis")
    }
}
