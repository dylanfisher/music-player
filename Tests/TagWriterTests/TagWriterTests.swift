import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

/// The edits the round trip makes, as on the corpus (docs/plan.md, phase 11).
private func edits(for url: URL) throws -> [(String, TagEdit)] {
    let layout = try readTagLayout(at: url)
    let current = try tags(url)
    let title = current.title ?? "Title"
    let long = String(repeating: "Long title ", count: (layout.paddingBytes + 4096) / 11)
    var result: [(String, TagEdit)] = [
        ("same-length title", TagEdit(values: [.title: String(title.reversed())])),
        ("shorter title", TagEdit(values: [.title: String(title.prefix(1))])),
        ("title past the padding", TagEdit(values: [.title: long])),
        ("non-ASCII title", TagEdit(values: [.title: "Perälä"])),
        ("numbers", TagEdit(values: [.trackNumber: "7", .trackTotal: "9", .discNumber: "2"])),
        ("compilation", TagEdit(values: [.compilation: current.compilation ? "" : "1"])),
        ("new art", TagEdit(art: .replace(pngImage(side: 64), mimeType: pngMIMEType))),
        ("smaller art", TagEdit(art: .replace(pngImage(side: 2), mimeType: pngMIMEType))),
        ("no art", TagEdit(art: .remove)),
    ]
    if current.album != nil { result.append(("cleared album", TagEdit(values: [.album: ""]))) }
    if current.composer == nil {
        result.append(("added composer", TagEdit(values: [.composer: "Sibelius"])))
    }
    return result
}

@Test(arguments: Sample.allCases)
func everyEditReadsBackAndUndoes(_ sample: Sample) throws {
    let url = try sample.copy()
    let pristine = try scratchCopy(of: url)
    let original = try Data(contentsOf: url)
    let originalTags = try tags(url)
    let originalArt = try art(url)
    let writer = scratchWriter()
    for (name, edit) in try edits(for: url) {
        let report = writer.write(edit, to: [url.path])
        // A WAV's LIST/INFO fills in a field its ID3 chunk lacks, so clearing one there can't
        // read back as cleared; the check refuses it and the file stays as it was.
        if sample == .wavInfoOnly || sample == .wavInfoAndID3, name == "cleared album" {
            #expect(report.failures.map(\.kind) == [.checkFailed], "\(name)")
            #expect(try Data(contentsOf: url) == original, "\(name)")
            continue
        }
        let expected = try edit.applied(to: originalTags)
        if expected == originalTags, edit.art == nil || (edit.art == .remove && originalArt == nil)
        {
            #expect(report.unchanged == [url.path], "\(name)")
            #expect(try Data(contentsOf: url) == original, "\(name)")
            continue
        }
        expectChanged(report, [url])
        #expect(try tags(url) == expected, "\(name)")
        switch edit.art {
        case .replace(let image, _): #expect(try art(url) == image, "\(name)")
        case .remove: #expect(try art(url) == nil, "\(name)")
        case nil: #expect(try art(url) == originalArt, "\(name)")
        }
        #expect(
            try untouchedBlockDifferences(original: pristine, edited: url, edit: edit) == [],
            "\(name)")
        expectChanged(writer.undoLast(), [url])
        #expect(try Data(contentsOf: url) == original, "undoing \(name)")
    }
    #expect(writer.undoLast().nothingToUndo)
}

@Test(arguments: [Sample.mp4, .mp3v24, .flac, .aiffV24])
func editsAfterARewriteFitInItsPadding(_ sample: Sample) throws {
    let url = try sample.copy()
    let writer = scratchWriter()
    let long = String(repeating: "x", count: try readTagLayout(at: url).paddingBytes + 100)
    expectChanged(writer.write(TagEdit(values: [.title: long]), to: [url.path]), [url])
    let grown = try readTagLayout(at: url)
    #expect(grown.paddingBytes >= 1024)
    expectChanged(writer.write(TagEdit(values: [.title: "Short"]), to: [url.path]), [url])
    let after = try readTagLayout(at: url)
    #expect(after.payload == grown.payload)
}

/// The fixture MP4 with `moov` moved after `mdat`, as 61 of the corpus files have it.
private func mp4WithMoovLast() throws -> URL {
    let url = try Sample.mp4.copy()
    let reader = ByteReader(try FileSource(path: url.path))
    let file = try MP4File(reader)
    #expect(file.audioAfterMoov)
    var moov = file.moov
    let mdat = file.mdats[0]
    let ftyp = file.top[0].atom
    for table in moov.chunkOffsetTables() {
        try moov[table].shiftChunkOffsets(by: ftyp.body.upperBound - mdat.start, from: 0)
    }
    let bytes = try Data(contentsOf: url)
    var moved = bytes[ftyp.start..<ftyp.body.upperBound]
    moved += bytes[mdat.start..<mdat.body.upperBound]
    moved += moov.serialized()
    try moved.write(to: url)
    return url
}

@Test func moovAfterTheAudioGrowsAtTheEnd() throws {
    let url = try mp4WithMoovLast()
    let original = try Data(contentsOf: url)
    let before = try readTagLayout(at: url)
    #expect(before.notes.contains("moov after mdat"))
    let writer = scratchWriter()
    let edit = TagEdit(values: [.title: String(repeating: "Perälä ", count: 400)])
    expectChanged(writer.write(edit, to: [url.path]), [url])
    #expect(try readTagLayout(at: url).payload == before.payload)
    #expect(try tags(url).title == edit.values[.title])
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}
