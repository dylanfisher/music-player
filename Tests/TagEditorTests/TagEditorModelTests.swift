import Foundation
import Testing

@testable import Metadata
@testable import TagEditor
@testable import TagWriter

private func track(_ name: String, album: String?, number: Int?, art: Data? = nil) -> EditableTrack
{
    var tags = TrackTags()
    tags.title = name
    tags.album = album
    tags.trackNumber = number
    return EditableTrack(path: "/music/\(name).flac", tags: tags, art: art)
}

@Test func sharedValuesShowAndDifferingOnesAreMixed() {
    let model = TagEditorModel(tracks: [
        track("A", album: "Same", number: 1), track("B", album: "Same", number: 2),
    ])
    #expect(model.text(.album) == "Same")
    #expect(!model.isMixed(.album))
    #expect(model.isMixed(.title))
    #expect(model.text(.title) == "")
    #expect(model.shared(.composer) == "", "no track has one, which isn't mixed")
    #expect(!model.isMixed(.composer))
}

@Test func onlyFieldsTypedDifferentlyAreInTheEdit() throws {
    var model = TagEditorModel(tracks: [
        track("A", album: "Same", number: 1), track("B", album: "Same", number: 2),
    ])
    model.set(.album, "Same")
    model.set(.title, "Both")
    model.set(.composer, "")
    #expect(try model.edit() == TagEdit(values: [.title: "Both"]))
    #expect(!model.isMixed(.title))
    model.set(.album, "")
    #expect(try model.edit().values[.album] == "", "clearing a shared value is an edit")
}

@Test func aMixedFieldTypedEmptyClearsItEverywhere() throws {
    var model = TagEditorModel(tracks: [
        track("A", album: "X", number: 1), track("B", album: "Y", number: 2),
    ])
    model.set(.album, "")
    #expect(try model.edit().values == [.album: ""])
}

@Test func badNumbersAreCaughtBeforeSaving() {
    var model = TagEditorModel(tracks: [track("A", album: nil, number: 1)])
    model.set(.trackNumber, "two")
    #expect(throws: TagValueError.self) { try model.edit() }
}

@Test func artIsSharedMixedReplacedOrRemoved() throws {
    let cover = Data([1, 2, 3])
    var model = TagEditorModel(tracks: [
        track("A", album: nil, number: nil, art: cover),
        track("B", album: nil, number: nil, art: cover),
    ])
    #expect(model.shownArt == cover)
    #expect(model.canRemoveArt)
    model.removeArt()
    #expect(model.shownArt == nil)
    #expect(!model.canRemoveArt)
    #expect(try model.edit().art == .remove)
    model.replaceArt(Data([9]), mimeType: pngMIMEType)
    #expect(try model.edit().art == .replace(Data([9]), mimeType: pngMIMEType))

    let mixed = TagEditorModel(tracks: [
        track("A", album: nil, number: nil, art: cover), track("B", album: nil, number: nil),
    ])
    #expect(mixed.isArtMixed)
    #expect(mixed.shownArt == nil)
    #expect(try mixed.edit().art == nil)
}

@Test func unreadableFilesAreReportedAndTheRestOpen() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tageditor-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let junk = folder.appendingPathComponent("junk.mp3")
    try Data("not audio".utf8).write(to: junk)
    let (tracks, problems) = readEditableTracks([
        junk.path, folder.appendingPathComponent("gone.flac").path,
    ])
    #expect(tracks.isEmpty)
    #expect(problems.count == 2)
}

@Test func editingAFieldWithSeveralValuesSaysOnlyOneIsKept() {
    var several = track("A", album: "X", number: 1)
    several.multiValued = [.artist]
    var model = TagEditorModel(tracks: [several, track("B", album: "X", number: 2)])
    #expect(model.collapseNote == nil, "nothing edited yet")
    model.set(.album, "Y")
    #expect(model.collapseNote == nil, "the album holds one value")
    model.set(.artist, "Both")
    #expect(model.collapsedFields == [.artist])
    #expect(
        model.collapseNote
            == "Artist holds several values in 1 file. Saving keeps only the value shown.")
}
