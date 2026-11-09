import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

/// Every picture in the file at `url`, in its order, with its type.
private func pictures(_ url: URL) throws -> [(image: Data, type: PictureType?)] {
    try readMetadata(at: url, pictures: true).metadata.pictures.map {
        (try readArt($0.art, at: url), $0.type)
    }
}

private let back = ArtPicture(image: pngImage(side: 16), mimeType: pngMIMEType, type: .backCover)
private let front = ArtPicture(image: pngImage(side: 24), mimeType: pngMIMEType, type: .frontCover)
private let label = ArtPicture(image: pngImage(side: 8), mimeType: jpegMIMEType, type: .discLabel)

/// A list of pictures replaces every picture a file holds, in its order with its types, and
/// MP4, which keeps no types, gets the front cover first; the file reads back as written, the
/// rest of it is untouched, and Undo Tag Edit puts the old pictures back (ADR 0172).
@Test(arguments: Sample.allCases)
func aListOfPicturesReadsBackAndUndoes(_ sample: Sample) throws {
    let url = try sample.copy()
    let pristine = try scratchCopy(of: url)
    let original = try Data(contentsOf: url)
    let writer = scratchWriter()
    let edit = TagEdit(art: .pictures([back, front, label]))
    expectChanged(writer.write(edit, to: [url.path]), [url])
    let read = try pictures(url)
    if sample == .mp4 || sample == .mp4WithArt {
        #expect(read.map(\.image) == [front, back, label].map(\.image))
        #expect(read.map(\.type) == [nil, nil, nil])
    } else {
        #expect(read.map(\.image) == [back, front, label].map(\.image))
        #expect(read.map(\.type) == [.backCover, .frontCover, .discLabel])
    }
    #expect(try art(url) == front.image, "the front cover is the art shown")
    #expect(try untouchedBlockDifferences(original: pristine, edited: url, edit: edit) == [])

    expectChanged(writer.write(TagEdit(art: .pictures([label])), to: [url.path]), [url])
    #expect(try pictures(url).map(\.image) == [label.image])
    expectChanged(writer.write(TagEdit(art: .pictures([])), to: [url.path]), [url])
    #expect(try pictures(url).isEmpty)

    for _ in 0..<3 { expectChanged(writer.undoLast(), [url]) }
    #expect(try Data(contentsOf: url) == original)
}

/// ID3 allows one picture a description, so each frame after the first gets its type's name,
/// numbered when it repeats.
@Test(arguments: [Sample.mp3v23, .mp3v24WithArt, .aiffV24])
func id3PicturesHaveADescriptionEach(_ sample: Sample) throws {
    let url = try sample.copy()
    let writer = scratchWriter()
    var second = back
    second.image = pngImage(side: 12)
    expectChanged(
        writer.write(TagEdit(art: .pictures([front, back, second])), to: [url.path]), [url])
    let bytes = try Data(contentsOf: url)
    #expect(bytes.range(of: Data("Back Cover\0".utf8)) != nil)
    #expect(bytes.range(of: Data("Back Cover 2\0".utf8)) != nil)
    #expect(bytes.range(of: Data("Front Cover".utf8)) == nil, "the first has none")
}

/// A picture that isn't a JPEG or PNG, as one kept from the file, is written back with its own
/// bytes and MIME type; only a replacement front cover is limited to those two (ADR 0172).
@Test(arguments: Sample.allCases)
func aKeptPictureOfAnotherTypeIsWrittenBackAsItWas(_ sample: Sample) throws {
    let url = try sample.copy()
    let writer = scratchWriter()
    let gif = ArtPicture(
        image: Data("GIF89a".utf8) + Data(repeating: 1, count: 20), mimeType: gifMIMEType,
        type: .backCover)
    expectChanged(writer.write(TagEdit(art: .pictures([front, gif])), to: [url.path]), [url])
    let mime = try readMetadata(at: url, pictures: true).metadata.pictures.map(\.art.mimeType)
    #expect(mime == [pngMIMEType, gifMIMEType])
    #expect(try pictures(url).map(\.image) == [front.image, gif.image])
}

/// A replacement front cover of a type no format labels is refused before anything is written.
@Test func aReplacementThatIsNeitherJPEGNorPNGIsRefused() throws {
    #expect(throws: TagValueError.self) {
        try TagEdit(art: .replace(Data([1]), mimeType: gifMIMEType)).applied(to: TrackTags())
    }
}
