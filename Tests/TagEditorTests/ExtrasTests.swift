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
private func fixture(_ container: FixtureFile.Container, _ format: FixtureFile.TagFormat) throws
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

private func track(_ name: String, _ custom: [String: String]) -> EditableTrack {
    var tags = TrackTags()
    tags.custom = custom
    return EditableTrack(path: "/music/\(name).flac", tags: tags, art: nil)
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

/// The tab shows a key and its value a line, read only, so they can be selected and copied.
@MainActor @Test func theExtrasTabIsReadOnlyText() {
    let editor = TagEditorWindow(paths: ["/music/a.flac", "/music/b.flac"])
    defer { editor.close() }
    editor.load(
        TagEditorModel(tracks: [
            track("a", ["SAME": "1", "DIFFERS": "x"]), track("b", ["SAME": "1", "DIFFERS": "y"]),
        ]))
    #expect(editor.extrasText.string == "DIFFERS\tMixed\nSAME\t1")
    #expect(!editor.extrasText.isEditable)
    #expect(editor.extrasText.isSelectable)
}
