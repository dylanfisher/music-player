import Foundation
import Testing

@testable import Metadata
@testable import TagEditor
@testable import TagWriter

@Test func everyEditableFieldIsOnATab() {
    let shown = Set(TagEditorTab.allCases.flatMap { $0.rows.flatMap(\.fields) })
    #expect(shown == Set(TagEditField.allCases))
}

@Test func eachSortFieldSitsDirectlyAboveTheFieldItSorts() {
    let rows = TagEditorTab.sorting.rows
    let pairs: [(TagEditField, TagEditField)] = [
        (.titleSort, .title), (.artistSort, .artist), (.albumArtistSort, .albumArtist),
        (.albumSort, .album), (.composerSort, .composer),
    ]
    for (sort, sorted) in pairs {
        let index = rows.firstIndex(of: .wide(sort))
        #expect(index.map { rows[$0 + 1] } == .wide(sorted), "\(sort)")
    }
}

private func track(_ name: String, _ change: (inout TrackTags) -> Void) -> EditableTrack {
    var tags = TrackTags()
    tags.title = name
    change(&tags)
    return EditableTrack(path: "/music/\(name).flac", tags: tags, art: nil)
}

@Test func theNewFieldsShowSharedOrMixedAndOnlyEditedOnesAreSaved() throws {
    var model = TagEditorModel(tracks: [
        track("A") {
            $0.conductor = "Salonen"
            $0.lyrics = "One\nTwo"
            $0.movementTotal = 4
            $0.artistSort = "Petrov, Yuki"
        },
        track("B") {
            $0.conductor = "Salonen"
            $0.lyrics = "Other"
            $0.movementTotal = 4
        },
    ])
    #expect(model.text(.conductor) == "Salonen")
    #expect(model.text(.movementTotal) == "4")
    #expect(model.isMixed(.lyrics))
    #expect(model.isMixed(.artistSort))
    #expect(!model.isEdited(.conductor))

    model.set(.conductor, "Salonen")
    #expect(!model.isEdited(.conductor), "typed back to what it showed")
    model.set(.lyrics, "Shared\nlines")
    model.set(.bpm, "128")
    #expect(model.isEdited(.lyrics))
    #expect(model.isEdited(.bpm))
    #expect(try model.edit() == TagEdit(values: [.lyrics: "Shared\nlines", .bpm: "128"]))

    model.set(.movementNumber, "two")
    #expect(throws: TagValueError.self) { try model.edit() }
}

@Test func theFileTabShowsTheFormatAndTheAverageBitRate() {
    let audio = TrackAudio(
        codec: .flac, sampleRateHz: 96_000, bitsPerSample: 24, channels: 2,
        lengthFrames: 96_000 * 10)
    let file = FileFacts(
        audio: audio, sizeBytes: 1_250_000, tagScheme: "Vorbis comment",
        modified: Date(timeIntervalSince1970: 0), created: Date(timeIntervalSince1970: 0))
    let one = EditableTrack(path: "/music/a.flac", tags: TrackTags(), art: nil, file: file)
    #expect(FileRow.format.text(one) == "FLAC")
    #expect(FileRow.sampleRate.text(one) == "96 kHz")
    #expect(FileRow.bitDepth.text(one) == "24-bit")
    #expect(FileRow.length.text(one) == "0:10")
    #expect(FileRow.bitRate.text(one) == "1000 kbps")
    #expect(FileRow.tag.text(one) == "Vorbis comment")
    #expect(FileRow.folder.text(one) == "/music")
}
