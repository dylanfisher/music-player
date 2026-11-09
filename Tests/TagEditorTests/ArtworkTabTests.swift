import AppKit
import Testing

@testable import Fixtures
@testable import Metadata
@testable import TagEditor
@testable import TagWriter

/// `image` as a file's only picture, its front cover; none for nil.
func frontCovers(_ image: Data?) -> [ArtPicture] {
    image.map { [ArtPicture(image: $0, mimeType: jpegMIMEType, type: .frontCover)] } ?? []
}

private let front = ArtPicture(image: Data([1]), mimeType: jpegMIMEType, type: .frontCover)
private let back = ArtPicture(image: Data([2]), mimeType: pngMIMEType, type: .backCover)

private func track(_ name: String, _ pictures: [ArtPicture]) -> EditableTrack {
    EditableTrack(path: "/music/\(name).flac", tags: TrackTags(), pictures: pictures)
}

/// The tab lists every picture the tracks share, with its type; adding, removing and
/// retyping edit the whole list, which is written in place of each file's pictures, and an
/// edit back to what the files hold is none (ADR 0172).
@Test func theArtworkTabEditsEveryPicture() throws {
    var model = TagEditorModel(tracks: [track("A", [back, front]), track("B", [back, front])])
    #expect(model.shownPictures == [back, front])
    #expect(model.shownArt == front.image, "the front cover is the one shown")
    model.addPictures([(Data([3]), pngMIMEType)])
    let added = ArtPicture(image: Data([3]), mimeType: pngMIMEType, type: .other)
    #expect(model.shownPictures == [back, front, added], "a second front cover isn't guessed")
    model.setPictureType(.discLabel, at: 2)
    model.removePictures(at: [0])
    var label = added
    label.type = .discLabel
    #expect(try model.edit().art == .pictures([front, label]))

    model.removePictures(at: [1])
    model.addPictures([(Data([2]), pngMIMEType)])
    model.setPictureType(.backCover, at: 1)
    model.removePictures(at: [0])
    model.addPictures([(Data([1]), jpegMIMEType)])
    model.setPictureType(.frontCover, at: 1)
    #expect(model.shownPictures == [back, front])
    #expect(model.art == .unchanged, "the files hold that already")
    model.removePictures(at: [0, 1])
    #expect(try model.edit().art == .remove)
}

/// Tracks whose pictures differ show none, mixed, and keep theirs unless the list is
/// changed; a picture added then becomes every file's only one.
@Test func mixedPicturesAreLeftAloneUntilChanged() throws {
    var model = TagEditorModel(tracks: [track("A", [back, front]), track("B", [front])])
    #expect(model.isArtMixed)
    #expect(model.shownPictures.isEmpty)
    #expect(try model.edit().art == nil)
    model.addPictures([(Data([2]), pngMIMEType)])
    let only = ArtPicture(image: Data([2]), mimeType: pngMIMEType, type: .frontCover)
    #expect(try model.edit().art == .pictures([only]), "the first added is the front cover")
}

/// Replace Artwork… puts the new front cover where the shown one was, the rest kept.
@Test func aReplacedFrontCoverKeepsTheOtherPictures() {
    var model = TagEditorModel(tracks: [track("A", [back, front])])
    model.replaceArt(Data([9]), mimeType: pngMIMEType)
    let new = ArtPicture(image: Data([9]), mimeType: pngMIMEType, type: .frontCover)
    #expect(model.shownPictures == [back, new])
}

/// The editor reads every picture a file holds, with its type; MP4's have none, so its first
/// reads as the front cover and the rest as Other.
@Test(arguments: [
    (FixtureFile.Container.flac, FixtureFile.TagFormat.vorbisComment), (.mp4, .mp4),
])
func theEditorReadsEveryPicture(
    container: FixtureFile.Container, format: FixtureFile.TagFormat
) throws {
    let url = try fixture(container, format)
    let writer = TagWriter(journal: TagUndoJournal(dataDirectory: url.deletingLastPathComponent()))
    let pictures = [front, back].map {
        ArtPicture(
            image: $0.image + Data(repeating: 7, count: 32), mimeType: $0.mimeType, type: $0.type)
    }
    #expect(writer.write(TagEdit(art: .pictures(pictures)), to: [url.path]).failures == [])
    var expected = pictures
    if container == .mp4 { expected[1].type = .other }
    #expect(try readEditableTrack(url.path).pictures == expected)
}

/// The tab's list shows each picture, + adds what the open panel chose, Paste adds an image
/// on the pasteboard, and − removes the selected.
@MainActor @Test func theListAddsPastesAndRemoves() throws {
    let editor = TagEditorWindow(paths: ["/music/A.flac"])
    editor.show(after: nil)
    defer { editor.close() }
    editor.tabs.selectTabViewItem(withIdentifier: TagEditorTab.artwork.rawValue)
    // The next window opens on the tab last chosen, which the other tests take as Info.
    defer { editor.tabs.selectTabViewItem(withIdentifier: TagEditorTab.info.rawValue) }
    editor.load(TagEditorModel(tracks: [track("A", [front])]))
    #expect(editor.artworkList.table.numberOfRows == 1)
    #expect(editor.addPictureButton.isEnabled)

    let png = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )?.representation(using: .png, properties: [:]))
    editor.choosePictures = { $0([(png, pngMIMEType)], []) }
    editor.addPictureButton.sendAction(
        editor.addPictureButton.action, to: editor.addPictureButton.target)
    #expect(editor.artworkList.table.numberOfRows == 2)

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("tageditor-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    editor.artworkList.table.pasteboard = pasteboard
    editor.artworkList.table.paste(nil)
    #expect(editor.artworkList.table.numberOfRows == 3)

    editor.artworkList.table.selectRowIndexes([0, 2], byExtendingSelection: false)
    #expect(editor.removePictureButton.isEnabled)
    editor.removePictureButton.sendAction(
        editor.removePictureButton.action, to: editor.removePictureButton.target)
    #expect(editor.model?.shownPictures.map(\.image) == [png])
}
