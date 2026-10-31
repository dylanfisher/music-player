import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

@Test func anEntryWithAnUnknownKeyAnywhereIsDiscardedAndReported() throws {
    let url = try Sample.mp3v24.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    expectChanged(writer.write(TagEdit(values: [.title: "Two"]), to: [url.path]), [url])
    let newest = writer.journal.directory.appendingPathComponent("00000002.json")
    var json = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: newest)) as? [String: Any])
    var files = try #require(json["files"] as? [[String: Any]])
    files[0]["extra"] = true
    json["files"] = files
    try JSONSerialization.data(withJSONObject: json).write(to: newest)

    let report = writer.undoLast()
    #expect(report.failures.map(\.kind) == [.journal, .changedSinceEdit])
    #expect(!FileManager.default.fileExists(atPath: newest.path))
}

@Test func theJournalKeepsTheNewestEdits() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    for index in 0...TagUndoJournal.capacity {
        expectChanged(
            writer.write(TagEdit(values: [.title: "Take \(index)"]), to: [url.path]), [url])
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: writer.journal.directory.path)
    #expect(names.sorted().first == "00000002.json")
    #expect(names.count == TagUndoJournal.capacity)
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
