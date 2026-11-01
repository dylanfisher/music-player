import Darwin
import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

private let titleEdit = TagEdit(values: [.title: "Edited"])

/// The MP4 sample with `extra` appended inside its `moov`.
private func mp4(withInMoov extra: Data) throws -> URL {
    let url = try Sample.mp4.copy()
    let file = try MP4File(ByteReader(FileSource(path: url.path)))
    let moov = file.moov.serialized()
    precondition(!file.moov.largeSize, "the sample's moov has a 32-bit size")
    let body = Data(moov[8...]) + extra
    var header = Data(bigEndianBytes(body.count + 8, 4))
    header += Data(MP4Type.moov.utf8)
    let bytes = try Data(contentsOf: url)
    try (bytes[..<file.moovAtom.start] + header + body + bytes[file.moovAtom.body.upperBound...])
        .write(to: url)
    return url
}

@Test func aDeeplyNestedMP4IsRefusedByTheWriter() throws {
    // A hundred thousand `udta`s, each holding the next: the reader skips them, and a writer that
    // opened each one would recurse until the stack ran out.
    let depth = 100_000
    var nested = Data()
    for level in 0..<depth {
        nested += Data(bigEndianBytes(8 * (depth - level), 4)) + Data(MP4Type.udta.utf8)
    }
    let url = try mp4(withInMoov: nested)
    _ = try readMetadata(at: url)
    let original = try Data(contentsOf: url)
    let report = scratchWriter().write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.unsupported])
    #expect(report.failures.first?.detail.contains("nested more than") == true)
    #expect(try Data(contentsOf: url) == original)
}

@Test func aSymbolicLinkIsRefusedAndItsTargetUnchanged() throws {
    let target = try Sample.flac.copy()
    let original = try Data(contentsOf: target)
    let link = scratchFolder().appendingPathComponent("link.flac")
    #expect(symlink(target.path, link.path) == 0)
    let report = scratchWriter().write(titleEdit, to: [link.path])
    #expect(report.failures.map(\.kind) == [.unsupported])
    #expect(report.failures.first?.detail == FileFailure.notRegular)
    #expect(try Data(contentsOf: target) == original)
    let info = try FileManager.default.attributesOfItem(atPath: link.path)
    #expect(info[.type] as? FileAttributeType == .typeSymbolicLink)
}
