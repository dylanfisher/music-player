import AppKit
import Foundation
import Testing

@testable import Fixtures
@testable import Metadata
@testable import TagEditor
@testable import TagWriter

/// A generated DSF or DSDIFF file with a title and artist in its ID3v2 tag, or none, in a
/// folder of its own.
func dsdFixture(_ fileExtension: String, tagged: Bool = true) throws -> URL {
    let tags = FixtureTags(title: "Mack The Knife", artist: "Louis Armstrong", compilation: false)
    let tag =
        tagged
        ? id3Tag(
            tags, art: nil,
            style: ID3Style(
                version: .v24, preferUTF16: false, genreAsReference: false, paddingBytes: 0))
        : nil
    let channels = (0..<2).map { dsdTone(samples: 8 * 4096, rateHz: 2_822_400, channel: $0) }
    let bytes =
        fileExtension == "dsf"
        ? dsfFile(rateHz: 2_822_400, channels: channels, tag: tag)
        : dffFile(rateHz: 2_822_400, channels: channels, tag: tag)
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("tageditor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("track.\(fileExtension)", isDirectory: false)
    try bytes.write(to: url)
    return url
}

/// Get Info reads a DSF or DSDIFF file's tags with the reader alone, and says why they can't be
/// saved.
@Test(arguments: [("dsf", "DSF"), ("dff", "DSDIFF")])
func aDSDFileReadsItsTagsAndSaysWhyTheyCantBeSaved(fileExtension: String, name: String) throws {
    let url = try dsdFixture(fileExtension)
    let track = try readEditableTrack(url.path)
    #expect(track.tags.title == "Mack The Knife")
    #expect(track.tags.artist == "Louis Armstrong")
    #expect(track.readOnly == "Tags in \(name) files can't be written yet")
    #expect(track.file?.tagScheme == "ID3v2")
    #expect(track.file?.audio.codec == .dsd)

    let untagged = try readEditableTrack(dsdFixture(fileExtension, tagged: false).path)
    #expect(untagged.tags == TrackTags())
    #expect(untagged.file?.tagScheme == "No tag")
    #expect(untagged.readOnly != nil)
}

private func track(_ path: String, title: String, readOnly: String? = nil, art: Data? = nil)
    -> EditableTrack
{
    var tags = TrackTags()
    tags.title = title
    return EditableTrack(path: path, tags: tags, art: art, readOnly: readOnly)
}

private let dsfRefusal = "Tags in DSF files can't be written yet"

/// The fields show every track, read-only ones too, but an edit is checked against, and art
/// removed from, only the tracks Save writes.
@Test func aMixedSelectionEditsOnlyTheWritableTracks() throws {
    let all = TagEditorModel(tracks: [
        track("/a.dsf", title: "A", readOnly: dsfRefusal),
        track("/b.dsf", title: "B", readOnly: dsfRefusal),
    ])
    #expect(!all.canSave)
    #expect(all.readOnlyNote == "Tags in DSF files can't be written yet.")

    var mixed = TagEditorModel(tracks: [
        track("/a.dsf", title: "Same", readOnly: dsfRefusal, art: Data([1])),
        track("/b.flac", title: "Same"), track("/c.flac", title: "Same"),
    ])
    #expect(mixed.canSave)
    #expect(mixed.shared(.title) == "Same", "the read-only file's value shows too")
    #expect(
        mixed.readOnlyNote
            == "Tags in DSF files can't be written yet. Save writes only the other 2 files.")
    #expect(mixed.writable.map(\.path) == ["/b.flac", "/c.flac"])
    #expect(!mixed.canRemoveArt, "only the read-only file has art")
    mixed.set(.title, "New")
    #expect(try mixed.edit().values == [.title: "New"])

    let one = TagEditorModel(tracks: [
        track("/a.flac", title: "A"), track("/b.dsf", title: "B", readOnly: dsfRefusal),
    ])
    #expect(
        one.readOnlyNote
            == "Tags in DSF files can't be written yet. Save writes only the other 1 file.")
    #expect(TagEditorModel(tracks: [track("/a.flac", title: "A")]).readOnlyNote == nil)
}

/// A window on files that can't be saved shows their values, can't be typed in or saved, and
/// says why.
@MainActor @Test func aWindowOnReadOnlyFilesShowsThemAndCantSave() throws {
    let editor = TagEditorWindow(paths: ["/a.dsf"])
    defer { editor.close() }
    var saves = 0
    editor.saved = { _ in saves += 1 }
    editor.load(
        TagEditorModel(tracks: [track("/a.dsf", title: "Read only", readOnly: dsfRefusal)]))
    let title = try #require(editor.fields[.title]?.first)
    #expect(title.stringValue == "Read only")
    #expect(!title.isEditable)
    #expect(!editor.saveButton.isEnabled)
    #expect(editor.problemLabel.stringValue == "Tags in DSF files can't be written yet.")
    editor.saveButton.performClick(nil)
    #expect(saves == 0)

    let mixed = TagEditorWindow(paths: ["/a.dsf", "/b.flac"])
    defer { mixed.close() }
    mixed.load(
        TagEditorModel(tracks: [
            track("/a.dsf", title: "A", readOnly: dsfRefusal), track("/b.flac", title: "B"),
        ]))
    #expect(mixed.fields[.title]?.first?.isEditable == true)
    #expect(mixed.saveButton.isEnabled)
}

/// A Save error takes the line beside the buttons, and the note about the files that can't be
/// saved comes back at the next change.
@MainActor @Test func theReadOnlyNoteComesBackAfterASaveError() throws {
    let editor = TagEditorWindow(paths: ["/a.dsf", "/b.flac"])
    defer { editor.close() }
    var saves = 0
    editor.saved = { _ in saves += 1 }
    editor.load(
        TagEditorModel(tracks: [
            track("/a.dsf", title: "A", readOnly: dsfRefusal), track("/b.flac", title: "B"),
        ]))
    let note = "Tags in DSF files can't be written yet. Save writes only the other 1 file."
    #expect(editor.problemLabel.stringValue == note)

    let type = { (field: TagEditField, text: String) in
        let view = try #require(editor.fields[field]?.first)
        view.stringValue = text
        editor.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: view))
    }
    try type(.trackNumber, "not a number")
    editor.saveButton.performClick(nil)
    #expect(saves == 0)
    #expect(editor.problemLabel.stringValue != note, "the error shows")

    try type(.trackNumber, "3")
    #expect(editor.problemLabel.stringValue == note)
    editor.saveButton.performClick(nil)
    #expect(saves == 1)
    #expect(editor.problemLabel.stringValue == note)
}
