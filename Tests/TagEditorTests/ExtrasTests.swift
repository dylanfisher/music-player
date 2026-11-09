import AppKit
import Foundation
import Testing

@testable import Fixtures
@testable import Metadata
@testable import TagEditor
@testable import TagWriter

/// A fixture library of this target's own, since test targets run in one process and would
/// otherwise generate into the same directory at once.
private let fixtureLibrary = Result { () throws -> (URL, FixtureManifest) in
    let root = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/tageditor-tests", isDirectory: true)
    // Enough files for one of each format the tests pick.
    _ = try generateFixtures(count: 100, in: root)
    return (root, try loadManifest(in: root))
}

/// A copy, in a folder of its own, of the library's first well-formed tagged file in
/// `container` with tags in `format`.
func fixture(_ container: FixtureFile.Container, _ format: FixtureFile.TagFormat) throws
    -> URL
{
    let (root, manifest) = try fixtureLibrary.get()
    let file = try #require(
        manifest.files.first {
            $0.malformation == nil && $0.tags != nil && $0.container == container
                && $0.tagFormats == [format]
        })
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("tageditor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(
        (file.path as NSString).lastPathComponent, isDirectory: false)
    try FileManager.default.copyItem(
        at: root.appendingPathComponent(file.path, isDirectory: false), to: copy)
    return copy
}

private let custom = [
    "DISCOGS_RELEASE_ID": "1234567", "MUSICBRAINZ_ALBUMID": "a1b2c3", "SOURCE": "Vinyl rip",
]

/// Extras lists the keys no field maps as each format holds them: Vorbis comments, MP4
/// freeform items and ID3 `TXXX` frames (53.8).
@Test(arguments: [
    (FixtureFile.Container.flac, FixtureFile.TagFormat.vorbisComment), (.mp4, .mp4),
    (.mp3, .id3v24),
])
func extrasListEveryKeyNoFieldMaps(
    container: FixtureFile.Container, format: FixtureFile.TagFormat
) throws {
    let url = try fixture(container, format)
    let writer = TagWriter(
        journal: TagUndoJournal(dataDirectory: url.deletingLastPathComponent()))
    let report = writer.write(TagEdit(custom: custom), to: [url.path])
    #expect(report.failures.isEmpty)
    let model = TagEditorModel(tracks: [try readEditableTrack(url.path)])
    #expect(
        model.extras == custom.keys.sorted().map { ExtraRow(key: $0, value: custom[$0]) },
        "\(container)")
}

private func track(
    _ name: String, _ custom: [String: String], codec: TrackAudio.Codec? = nil,
    readOnly: String? = nil
) -> EditableTrack {
    var tags = TrackTags()
    tags.custom = custom
    let file = codec.map {
        FileFacts(
            audio: TrackAudio(
                codec: $0, sampleRateHz: 44_100, bitsPerSample: 16, channels: 2,
                lengthFrames: 44_100),
            sizeBytes: 1, tagScheme: "", modified: Date(timeIntervalSince1970: 0),
            created: Date(timeIntervalSince1970: 0))
    }
    return EditableTrack(
        path: "/music/\(name).flac", tags: tags, pictures: [], file: file, readOnly: readOnly)
}

/// A key shows its value only where every file has it and they agree.
@Test func aKeyThatDiffersOrIsMissingFromAFileIsMixed() {
    let model = TagEditorModel(tracks: [
        track("a", ["SAME": "1", "DIFFERS": "x", "ONLY_A": "a"]),
        track("b", ["SAME": "1", "DIFFERS": "y"]),
    ])
    #expect(
        model.extras == [
            ExtraRow(key: "DIFFERS", value: nil), ExtraRow(key: "ONLY_A", value: nil),
            ExtraRow(key: "SAME", value: "1"),
        ])
    #expect(TagEditorModel(tracks: [track("c", [:])]).extras.isEmpty)
}

/// A value typed, a key deleted and a key added in Extras go into the edit Save writes: the
/// new text, empty text to remove a key, and the added key uppercased.
@Test func anEditADeleteAndAnAddInExtrasMakeTheEdit() throws {
    var model = TagEditorModel(tracks: [track("a", ["SOURCE": "Vinyl", "OLD": "x"])])
    model.setExtra("SOURCE", "CD")
    model.deleteExtra("OLD")
    #expect(model.addExtra("Ripper") == nil)
    model.setExtra("RIPPER", "dbpoweramp")
    #expect(
        model.extras == [
            ExtraRow(key: "RIPPER", value: "dbpoweramp", isEdited: true),
            ExtraRow(key: "SOURCE", value: "CD", isEdited: true),
        ])
    #expect(
        try model.edit()
            == TagEdit(custom: ["SOURCE": "CD", "OLD": "", "RIPPER": "dbpoweramp"]))

    // A value typed back, a key added and left empty, and one added then deleted, change
    // nothing; a key deleted and added again shows what it held.
    var back = TagEditorModel(tracks: [track("a", ["SOURCE": "Vinyl", "OLD": "x"])])
    back.setExtra("SOURCE", "CD")
    back.setExtra("SOURCE", "Vinyl")
    #expect(back.addExtra("EMPTY") == nil)
    #expect(back.addExtra("GONE") == nil)
    back.deleteExtra("GONE")
    back.deleteExtra("OLD")
    #expect(back.addExtra("old") == nil)
    #expect(back.extras.first { $0.key == "OLD" } == ExtraRow(key: "OLD", value: "x"))
    #expect(try back.edit().isEmpty)
}

/// For several files, a key that differs shows as mixed and is left alone unless typed in;
/// then the new value goes to every file. A key deleted is removed from every file holding it.
@Test func severalFilesKeepAMixedKeyUnlessItIsTyped() throws {
    let tracks = [
        track("a", ["SAME": "1", "DIFFERS": "x", "ONLY_A": "a"]),
        track("b", ["SAME": "1", "DIFFERS": "y"]),
    ]
    var model = TagEditorModel(tracks: tracks)
    model.setExtra("SAME", "2")
    #expect(try model.edit() == TagEdit(custom: ["SAME": "2"]), "the mixed keys are left alone")

    model.setExtra("DIFFERS", "z")
    model.deleteExtra("ONLY_A")
    #expect(model.extras.first { $0.key == "DIFFERS" }?.value == "z")
    #expect(try model.edit() == TagEdit(custom: ["SAME": "2", "DIFFERS": "z", "ONLY_A": ""]))
}

/// A key's name is checked as the writer checks it, and refused with why, adding nothing: a
/// name no format holds, a field's, one already listed, or an ID3 frame for another format.
@Test func aKeyExtrasCantHoldIsRefused() throws {
    var model = TagEditorModel(tracks: [track("a", ["SOURCE": "Vinyl"], codec: .flac)])
    let before = model
    #expect(model.addExtra("TITLE") == "\"TITLE\" is a field's name, not a custom key's")
    #expect(model.addExtra("artist") != nil, "a field's name in any case")
    #expect(
        model.addExtra("A=B")
            == "\"A=B\" isn't a custom key's name: printable ASCII without \"=\"")
    #expect(model.addExtra("") != nil)
    #expect(model.addExtra("source") == "\"SOURCE\" is already in Extras")
    #expect(
        model.addExtra("WXXX:Discogs")
            == "\"WXXX:DISCOGS\" is an ID3 frame, which vorbis doesn't hold")
    #expect(model == before)

    var mp3 = TagEditorModel(tracks: [track("a", [:], codec: .mp3)])
    #expect(mp3.addExtra("WXXX:Discogs") == nil)

    // An ID3 frame an MP3 holds can't be changed with a FLAC file selected too, since the
    // writer would refuse the FLAC file.
    var both = TagEditorModel(tracks: [
        track("a", ["WXXX:DISCOGS": "https://discogs.com"], codec: .mp3),
        track("b", [:], codec: .flac),
    ])
    both.deleteExtra("WXXX:DISCOGS")
    #expect(throws: TagValueError.self) { try both.edit() }
}

/// Only the files Save writes are checked and changed: a key only a read-only file holds
/// isn't removed from the others.
@Test func extrasEditOnlyTheWritableFiles() throws {
    var model = TagEditorModel(tracks: [
        track("a", ["ONLY_DSF": "1"], codec: .dsd, readOnly: "Tags can't be written"),
        track("b", ["SOURCE": "x"], codec: .flac),
    ])
    model.deleteExtra("ONLY_DSF")
    model.setExtra("SOURCE", "y")
    #expect(try model.edit() == TagEdit(custom: ["SOURCE": "y"]))
}

/// The tab is a table of keys and values: a value is typed in as a field is, with a dot by an
/// edited key, − removes the selected keys and + adds one, or says why it can't. Nothing can
/// be typed or added for files that can't be saved.
@MainActor @Test func theExtrasTabEditsTheKeysInATable() throws {
    let editor = TagEditorWindow(paths: ["/music/a.flac", "/music/b.flac"])
    defer { editor.close() }
    var saved: [TagEdit] = []
    editor.saved = { saved.append($0) }
    editor.load(
        TagEditorModel(tracks: [
            track("a", ["SAME": "1", "DIFFERS": "x"]), track("b", ["SAME": "1", "DIFFERS": "y"]),
        ]))
    // Every tab built, so Extras is there; a full turn ends on the tab it began, which the
    // other tests' windows open on.
    for _ in editor.shownTabs { editor.stepTab(1) }
    let table = editor.extrasTable
    #expect(table.numberOfRows == 2)
    func cell(_ column: Int, _ row: Int) throws -> NSTextField {
        try #require(table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)
    }
    #expect(try cell(0, 0).stringValue.hasSuffix("DIFFERS"))
    #expect(try cell(1, 0).stringValue == "")
    #expect(try cell(1, 0).placeholderString == "Mixed")
    #expect(try cell(1, 1).stringValue == "1")
    #expect(try cell(1, 1).isEditable)
    #expect(try !cell(0, 1).isEditable)

    let value = try cell(1, 1)
    value.stringValue = "2"
    editor.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: value))
    #expect(editor.extraRows[1] == ExtraRow(key: "SAME", value: "2", isEdited: true))

    #expect(!editor.removeExtraButton.isEnabled, "nothing selected")
    table.selectRowIndexes([0], byExtendingSelection: false)
    click(editor.removeExtraButton)
    #expect(editor.extraRows.map(\.key) == ["SAME"])

    editor.addExtra("TITLE")
    #expect(editor.problemLabel.stringValue == "\"TITLE\" is a field's name, not a custom key's")
    var asked = 0
    editor.askExtraKey = { answer in
        asked += 1
        answer("Source")
    }
    click(editor.addExtraButton)
    #expect(asked == 1)
    #expect(editor.extraRows.map(\.key) == ["SAME", "SOURCE"])
    #expect(editor.problemLabel.stringValue == "", "the next change clears the error")

    click(editor.saveButton)
    #expect(saved == [TagEdit(custom: ["SAME": "2", "DIFFERS": ""])])

    let readOnly = TagEditorWindow(paths: ["/music/a.dsf"])
    defer { readOnly.close() }
    readOnly.load(
        TagEditorModel(tracks: [track("a", ["SAME": "1"], readOnly: "Tags can't be written")]))
    for _ in readOnly.shownTabs { readOnly.stepTab(1) }
    let readOnlyValue = readOnly.extrasTable.view(atColumn: 1, row: 0, makeIfNecessary: true)
    #expect((readOnlyValue as? NSTextField)?.isEditable == false)
    #expect(!readOnly.addExtraButton.isEnabled)
}
