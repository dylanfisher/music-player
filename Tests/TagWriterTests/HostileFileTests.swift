import Darwin
import Foundation
import Testing

@testable import Fixtures
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

@Test func aLinkPlantedAtATempNameIsRemovedAndItsTargetUnchanged() throws {
    let url = try Sample.mp3v24.copy()
    let target = scratchFolder().appendingPathComponent("elsewhere")
    let elsewhere = Data("not music".utf8)
    try elsewhere.write(to: target)
    let planted = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).planted.tagwrite").path
    #expect(symlink(target.path, planted) == 0)
    #expect(try leftoverTemps(for: url.path) == [planted])
    expectChanged(scratchWriter().write(titleEdit, to: [url.path]), [url])
    #expect(try tags(url).title == "Edited")
    #expect(try Data(contentsOf: target) == elsewhere)
    #expect(try leftoverTemps(for: url.path).isEmpty)
}

@Test func theClonedTempFileIsntOpenedThroughALink() throws {
    let folder = scratchFolder()
    let target = folder.appendingPathComponent("elsewhere")
    try Data("not music".utf8).write(to: target)
    let name = ".track.flac.planted.tagwrite"
    #expect(symlink(target.path, folder.appendingPathComponent(name).path) == 0)
    let folderDescriptor = open(folder.path, O_RDONLY | O_DIRECTORY)
    defer { close(folderDescriptor) }
    for cloned in [true, false] {
        let descriptor = openTemp(name, in: folderDescriptor, cloned: cloned)
        let failure = errno
        if descriptor >= 0 { close(descriptor) }
        #expect(descriptor < 0, "cloned: \(cloned)")
        #expect(failure == (cloned ? ELOOP : EEXIST), "cloned: \(cloned)")
    }
    #expect(try Data(contentsOf: target) == Data("not music".utf8))
}

/// A write whose temp file someone else changes just before the rename, as another user of a
/// shared folder could: each is refused, the original stays as it was, and the other file too.
@Test(arguments: ["a regular file", "a hard link to another file", "a second link"])
func aTempFileSwappedBeforeTheRenameIsRefused(_ swap: String) throws {
    let url = try Sample.flac.copy()
    let original = try Data(contentsOf: url)
    let other = scratchFolder().appendingPathComponent("other")
    let otherBytes = Data("someone else's".utf8)
    try otherBytes.write(to: other)
    let link = scratchFolder().appendingPathComponent("link").path
    var writer = scratchWriter()
    writer.faults.beforeReplacing = { _, temp in
        switch swap {
        case "a regular file":
            let copy = temp + ".copy"
            try FileManager.default.copyItem(atPath: temp, toPath: copy)
            guard rename(copy, temp) == 0 else { throw POSIXError(.EIO) }
        case "a hard link to another file":
            guard unlink(temp) == 0, Darwin.link(other.path, temp) == 0 else {
                throw POSIXError(.EIO)
            }
        default:
            guard Darwin.link(temp, link) == 0 else { throw POSIXError(.EIO) }
        }
    }
    let report = writer.write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.changedDuringWrite], "\(swap)")
    #expect(report.failures.first?.detail == tempChangedDetail, "\(swap)")
    #expect(try Data(contentsOf: url) == original, "\(swap)")
    #expect(try Data(contentsOf: other) == otherBytes, "\(swap)")
}

/// A temp file whose mtime moves when its handle closes, as an SMB server sets a written file's
/// last write time at close (MS-FSA 2.1.5.4): the write goes through, and undo still finds it.
@Test(arguments: [Sample.flac, Sample.mp4, Sample.mp3v24])
func aTempFileWhoseMtimeMovesAtItsCloseIsWritten(_ sample: Sample) throws {
    let url = try sample.copy()
    let original = try Data(contentsOf: url)
    var writer = scratchWriter()
    writer.faults.whenTempCloses = { temp in
        var info = stat()
        guard lstat(temp, &info) == 0 else { throw POSIXError(.EIO) }
        var times = [
            info.st_atimespec,
            timespec(tv_sec: info.st_mtimespec.tv_sec + 2, tv_nsec: info.st_mtimespec.tv_nsec),
        ]
        guard utimensat(AT_FDCWD, temp, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(.EIO)
        }
    }
    let report = writer.write(titleEdit, to: [url.path])
    #expect(report.failures.isEmpty, "\(report.failures)")
    #expect(report.changed == [url.path])
    #expect(try tags(url).title == "Edited")
    #expect(try leftoverTemps(for: url.path).isEmpty)
    #expect(writer.undoLast().changed == [url.path])
    #expect(try Data(contentsOf: url) == original)
}

/// Another file put at the temp file's name as the temp file closes is refused, and so is a
/// change to the temp file after that, before the rename.
@Test(arguments: ["swapped at the close", "changed before the rename"])
func aTempFileReplacedAfterItClosesIsRefused(_ change: String) throws {
    let url = try Sample.flac.copy()
    let original = try Data(contentsOf: url)
    var writer = scratchWriter()
    if change == "swapped at the close" {
        writer.faults.whenTempCloses = { temp in
            let copy = temp + ".copy"
            try FileManager.default.copyItem(atPath: temp, toPath: copy)
            guard rename(copy, temp) == 0 else { throw POSIXError(.EIO) }
        }
    } else {
        writer.faults.beforeReplacing = { _, temp in
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temp))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
        }
    }
    let report = writer.write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.changedDuringWrite], "\(change)")
    let expected = change == "swapped at the close" ? tempSwapDetail : tempChangedDetail
    #expect(report.failures.first?.detail == expected, "\(change)")
    #expect(try Data(contentsOf: url) == original, "\(change)")
    #expect(try leftoverTemps(for: url.path).isEmpty, "\(change)")
}

/// The original swapped after it's read and before the temp file is made from it: the temp
/// file isn't made from the new one, or through a link.
@Test(arguments: ["a regular file", "a symbolic link"])
func anOriginalSwappedBeforeTheTempFileIsRefused(_ swap: String) throws {
    let url = try Sample.mp4.copy()
    let other = scratchFolder().appendingPathComponent("other.m4a")
    try FileManager.default.copyItem(at: url, to: other)
    let otherBytes = try Data(contentsOf: other)
    var writer = scratchWriter()
    writer.faults.beforeWritingTemp = { path in
        let staged = path + ".staged"
        if swap == "a regular file" {
            try FileManager.default.copyItem(atPath: path, toPath: staged)
        } else {
            guard symlink(other.path, staged) == 0 else { throw POSIXError(.EIO) }
        }
        guard rename(staged, path) == 0 else { throw POSIXError(.EIO) }
    }
    let report = writer.write(titleEdit, to: [url.path])
    let expected: TagWriteError.Kind = swap == "a regular file" ? .changedDuringWrite : .unreadable
    #expect(report.failures.map(\.kind) == [expected], "\(swap)")
    if swap == "a regular file" { #expect(report.failures.first?.detail == replacedDetail) }
    #expect(try Data(contentsOf: other) == otherBytes, "\(swap)")
    #expect(try leftoverTemps(for: url.path).isEmpty, "\(swap)")
}

/// The bytes of the MP4 file's `ilst` item `type`.
private func ilstItem(_ url: URL, _ type: String) throws -> [UInt8]? {
    let moov = try MP4File(ByteReader(FileSource(path: url.path))).moov
    guard let path = moov.indexPath(MP4File.ilstPath) else { return nil }
    return moov[path].children?.first { $0.type == type }?.serialized()
}

/// `url` with the first `marker` in it turned into a NUL, as a tagger that wrote one would.
private func plantNUL(in url: URL, at marker: String) throws {
    var bytes = try Data(contentsOf: url)
    let range = try #require(bytes.range(of: Data(marker.utf8)))
    bytes[range.lowerBound] = 0
    try bytes.write(to: url)
}

/// A field the reader cut at a NUL, edited or left alone beside an edit: the edited field
/// takes its new value, and the field the edit doesn't name keeps every byte, NUL and all.
@Test(arguments: [TagEditField.title, .artist])
func aFieldCutAtANULEditsAndKeepsItsNeighbour(_ edited: TagEditField) throws {
    let mp4 = try Sample.mp4.copy()
    let writer = scratchWriter()
    expectChanged(
        writer.write(TagEdit(values: [.title: "cut~after", .artist: "Neighbour"]), to: [mp4.path]),
        [mp4])
    try plantNUL(in: mp4, at: "~after")
    let flacURL = try flac(comments: ["TITLE=cut\u{0}after", "ARTIST=Neighbour"], padding: 512)
    for url in [mp4, flacURL] {
        #expect(try tags(url).title == "cut", "\(url.lastPathComponent)")
        let kept = edited == .title ? "Neighbour" : "cut\u{0}after"
        let keptItem =
            url == mp4 ? try ilstItem(url, edited == .title ? "\u{A9}ART" : "\u{A9}nam") : nil
        expectChanged(writer.write(TagEdit(values: [edited: "New"]), to: [url.path]), [url])
        let now = try tags(url)
        #expect((edited == .title ? now.title : now.artist) == "New", "\(url.lastPathComponent)")
        #expect(
            (edited == .title ? now.artist : now.title) == kept.components(separatedBy: "\u{0}")[0])
        #expect(
            try Data(contentsOf: url).range(of: Data(kept.utf8)) != nil, "\(url.lastPathComponent)")
        if let keptItem {
            #expect(try ilstItem(url, edited == .title ? "\u{A9}ART" : "\u{A9}nam") == keptItem)
        }
    }
}

@Test(arguments: ["dsf", "dff"])
func dsdFilesAreRefusedByTheWriterAndLeftUnchanged(fileExtension: String) throws {
    let channels = [Data(repeating: 0x69, count: 64), Data(repeating: 0x69, count: 64)]
    let bytes =
        fileExtension == "dsf"
        ? dsfFile(rateHz: 2_822_400, channels: channels)
        : dffFile(rateHz: 2_822_400, channels: channels)
    let url = scratchFolder().appendingPathComponent("track.\(fileExtension)")
    try bytes.write(to: url)
    let report = scratchWriter().write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.unsupported])
    #expect(report.failures.first?.detail.contains("DSF and DSDIFF") == true)
    #expect(try Data(contentsOf: url) == bytes)
}
