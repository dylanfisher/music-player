import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

/// An edit past the padding, read back, then undone byte for byte.
private func growAndUndo(_ url: URL) throws {
    let original = try Data(contentsOf: url)
    let writer = scratchWriter()
    let long = String(repeating: "Grown ", count: try readTagLayout(at: url).paddingBytes / 6 + 600)
    expectChanged(writer.write(TagEdit(values: [.title: long]), to: [url.path]), [url])
    #expect(try tags(url).title == long)
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}

@Test func co64EntriesMoveWithTheAudio() throws {
    let url = try mp4WithCo64()
    #expect(try readTagLayout(at: url).notes.contains("chunk offsets: co64"))
    try growAndUndo(url)
}

@Test func flacWithoutPaddingGetsSomeOnTheFirstRewrite() throws {
    let url = try flac(comments: ["TITLE=Bare"], padding: nil)
    #expect(try readTagLayout(at: url).paddingBytes == 0)
    try growAndUndo(url)
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "B"]), to: [url.path]), [url])
    #expect(try readTagLayout(at: url).paddingBytes > 0, "a shorter title leaves padding")
}

@Test(arguments: [Sample.aiffV24, .wavID3])
func anID3ChunkBeforeTheAudioMovesIt(_ sample: Sample) throws {
    let url = try formWithID3BeforeAudio(sample)
    #expect(try readTagLayout(at: url).notes.contains("ID3 chunk before the audio"))
    try growAndUndo(url)
}

@Test(arguments: [
    ("unsynchronised", UInt8(0x80), [UInt8]()),
    ("extended header", 0x40, [0, 0, 0, 6, 1, 0]),
    ("footer", 0x10, []),
])
func id3TagsTheWriterCantRewriteAreRefused(_ name: String, _ flags: UInt8, _ extended: [UInt8])
    throws
{
    var tag = id3Tag([extended + id3TextFrame("TIT2", "Odd", version: 4)], version: 4, flags: flags)
    if flags == 0x10 { tag += Array("3DI".utf8) + [4, 0, flags] + Array(tag[6..<10]) }
    let url = try mp3(withTag: tag)
    let original = try Data(contentsOf: url)
    let report = scratchWriter().write(TagEdit(values: [.title: "New"]), to: [url.path])
    #expect(report.failures.map(\.kind) == [.unsupported], "\(name)")
    #expect(report.failures.first?.detail.contains("extended header or footer") == true, "\(name)")
    #expect(try Data(contentsOf: url) == original, "\(name)")
}

@Test func aFragmentedMP4IsRefused() throws {
    let url = try Sample.mp4.copy()
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(bigEndianBytes(16, 4) + Array("moof".utf8) + zeros(8)))
    try handle.close()
    let original = try Data(contentsOf: url)
    let report = scratchWriter().write(TagEdit(values: [.title: "New"]), to: [url.path])
    #expect(report.failures.map(\.kind) == [.unsupported])
    #expect(report.failures.first?.detail.contains("fragmented") == true)
    #expect(try Data(contentsOf: url) == original)
}
