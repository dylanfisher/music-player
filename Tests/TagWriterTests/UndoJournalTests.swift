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
    // A write in place also has to confirm its record afterwards, which this folder refuses.
    writer.faults.writesInPlace = false
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

/// Each group's fields have a key the writer writes in every format, and the reader reads that
/// key as the field, so what the writer removes is all the reader reads.
@Test func everyGroupHasKeysInEveryFormat() {
    for group in TagGroup.allCases {
        // A pair's total shares its number's frame in ID3.
        for field in group.isPair ? [group.readerFields[0]] : group.readerFields {
            for version: UInt8 in [3, 4] {
                switch id3WrittenKey(for: field, version: version) {
                case .text(let id), .described(let id), .url(let id):
                    #expect(id3FrameIDs(for: field).contains(id), "\(field) in ID3v2.\(version)")
                case .userText(let description):
                    #expect(
                        id3UserTextDescriptions(for: field).contains(description),
                        "\(field) in ID3v2.\(version)")
                case nil: Issue.record("\(field) has no ID3v2.\(version) key")
                }
            }
        }
        switch group {
        case .track, .disc, .compilation:
            // Items of their own kind, a number and its total in one.
            #expect(!mp4ItemTypes(for: group.readerFields[0]).isEmpty, "\(group) in MP4")
        default:
            for field in group.readerFields {
                switch mp4WrittenKey(for: field) {
                case .item(let type): #expect(mp4ItemTypes(for: field).contains(type), "\(field)")
                case .freeform(let name):
                    #expect(mp4FreeformNames(for: field).contains(name.uppercased()), "\(field)")
                case nil: Issue.record("\(field) has no MP4 key")
                }
            }
        }
        for field in group.readerFields {
            let key = vorbisWrittenKey(for: field)
            #expect(key.map { vorbisKeys(for: field).contains($0) } == true, "\(field) in Vorbis")
        }
    }
}

/// The newest edit says which window made it and how many files it holds, without changing the
/// journal; an edit whose folder names no origin reads as unknown (ADR 0136).
@Test func theNewestEditSaysWhoMadeIt() throws {
    let urls = try [Sample.flac.copy(), Sample.mp3v24.copy()]
    let writer = scratchWriter()
    #expect(try writer.newestEdit() == nil)
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [urls[0].path]), [urls[0]])
    let edit = TagEdit(values: [.title: "Two"])
    expectChanged(
        writer.write(urls.map { ($0.path, edit) }, origin: .discogsTagger), urls)
    #expect(try writer.newestEdit()! == (.discogsTagger, 2))
    #expect(try writer.newestEdit()! == (.discogsTagger, 2), "nothing changed")

    expectChanged(writer.undoLast(), urls.reversed())
    #expect(try writer.newestEdit()! == (.tagEditor, 1))
    try FileManager.default.removeItem(
        at: try newestEntry(writer.journal).appendingPathComponent(TagUndoJournal.originName))
    #expect(try writer.newestEdit()! == (nil, 1))
    expectChanged(writer.undoLast(), [urls[0]])
}

/// The value of the extended attribute `name` of the file at `url`, nil without one.
private func attribute(_ name: String, of url: URL) -> [UInt8]? {
    let size = getxattr(url.path, name, nil, 0, 0, 0)
    guard size >= 0 else { return nil }
    var value = [UInt8](repeating: 0, count: size)
    return getxattr(url.path, name, &value, size, 0, 0) == size ? value : nil
}

private func inode(_ url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
}

/// A write in place never copies the attributes, so its undo, through a temp file, is the
/// first copy of them: a refused one the system manages is left off and the rest kept, and
/// any other refusal fails the undo with its name and leaves the edit undoable (ADR 0136).
@Test func anUndoThroughARefusedAttributeCopyOnlySkipsTheUnsettable() throws {
    let url = try Sample.mp3v24.copy()
    let original = try Data(contentsOf: url)
    let managed = "com.example.managed"
    #expect(setxattr(url.path, "com.example.note", "kept", 4, 0, 0) == 0)
    #expect(setxattr(url.path, managed, "system", 6, 0, 0) == 0)
    var writer = scratchWriter()
    writer.faults.unsettable.insert(managed)
    let before = try inode(url)
    expectChanged(writer.write(TagEdit(values: [.title: "Edited"]), to: [url.path]), [url])
    #expect(try inode(url) == before, "written in place")
    let edited = try Data(contentsOf: url)

    writer.faults.refusingAttribute = { $0 == "com.example.note" ? EACCES : nil }
    let refused = writer.undoLast()
    #expect(
        refused.failures.map(\.detail)
            == ["can't copy the extended attribute com.example.note: Permission denied"])
    #expect(try Data(contentsOf: url) == edited)

    writer.faults.refusingAttribute = { $0 == managed ? EACCES : nil }
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
    // The undo's temp file is an APFS clone here, which has every attribute already; on SMB,
    // which can't clone, it would start without the one left off.
    #expect(attribute("com.example.note", of: url) == Array("kept".utf8))
}

/// A write past the padding copies the attributes the same way, and a refused ACL names it.
@Test func aWriteThroughTheTempFileSkipsOnlyTheUnsettable() throws {
    let url = try Sample.mp3v24.copy()
    let managed = "com.example.managed"
    #expect(setxattr(url.path, "com.example.note", "kept", 4, 0, 0) == 0)
    #expect(setxattr(url.path, managed, "system", 6, 0, 0) == 0)
    let original = try Data(contentsOf: url)
    var writer = scratchWriter()
    writer.faults.unsettable.insert(managed)
    let long = TagEdit(values: [.title: String(repeating: "Long ", count: 20_000)])

    for (name, detail) in [
        ("com.example.note", "can't copy the extended attribute com.example.note"),
        ("acl", "can't copy its ACL"),
    ] {
        writer.faults.refusingAttribute = { $0 == name ? EPERM : nil }
        let report = writer.write(long, to: [url.path])
        #expect(report.failures.map(\.detail) == [detail + ": Operation not permitted"])
        #expect(try Data(contentsOf: url) == original)
    }

    writer.faults.refusingAttribute = { $0 == managed ? ENOTSUP : nil }
    expectChanged(writer.write(long, to: [url.path]), [url])
    #expect(attribute("com.example.note", of: url) == Array("kept".utf8))
    #expect(attribute(managed, of: url) == nil)
}
