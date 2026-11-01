import Darwin
import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

private let titleEdit = TagEdit(values: [.title: "Edited"])

@Test func aReadOnlyFileIsRefused() throws {
    let url = try Sample.mp3v24.copy()
    let original = try Data(contentsOf: url)
    chmod(url.path, 0o444)
    defer { chmod(url.path, 0o644) }
    let report = scratchWriter().write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.notWritable])
    #expect(try Data(contentsOf: url) == original)
}

@Test func aLockedFileIsRefused() throws {
    let url = try Sample.flac.copy()
    let original = try Data(contentsOf: url)
    chflags(url.path, UInt32(UF_IMMUTABLE))
    defer { chflags(url.path, 0) }
    let report = scratchWriter().write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.notWritable])
    #expect(try Data(contentsOf: url) == original)
}

@Test func aFileChangedDuringTheWriteIsLeftAsTheOtherWriterMadeIt() throws {
    let url = try Sample.mp4.copy()
    var writer = scratchWriter()
    writer.faults.beforeReplacing = { original, _ in
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: original))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
    }
    let report = writer.write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.changedDuringWrite])
    let changed = try Data(contentsOf: url)
    #expect(changed.last == 0)
    #expect(try tags(url).title != "Edited")
    #expect(!FileManager.default.fileExists(atPath: tempPath(for: url.path)))
    #expect(writer.undoLast().nothingToUndo)
}

@Test func aFailureBeforeTheRenameLeavesTheOriginalAndNoTempFile() throws {
    let url = try Sample.aiffV24.copy()
    let original = try Data(contentsOf: url)
    var writer = scratchWriter()
    writer.faults.beforeReplacing = { _, _ in throw POSIXError(.ENOSPC) }
    let report = writer.write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.writeFailed])
    #expect(try Data(contentsOf: url) == original)
    #expect(!FileManager.default.fileExists(atPath: tempPath(for: url.path)))
    #expect(writer.undoLast().nothingToUndo)
}

@Test func aCrashBeforeTheRenameLeavesTheOriginalAndTheNextWriteRecovers() throws {
    let url = try Sample.mp3v23.copy()
    let original = try Data(contentsOf: url)
    var writer = scratchWriter()
    writer.faults.crashBeforeRename = true
    _ = writer.write(titleEdit, to: [url.path])
    #expect(try Data(contentsOf: url) == original)
    #expect(FileManager.default.fileExists(atPath: tempPath(for: url.path)))
    // The journal kept the crashed edit, which no longer matches the file.
    writer.faults.crashBeforeRename = false
    #expect(writer.undoLast().failures.map(\.kind) == [.changedSinceEdit])
    expectChanged(writer.write(titleEdit, to: [url.path]), [url])
    #expect(try tags(url).title == "Edited")
    #expect(!FileManager.default.fileExists(atPath: tempPath(for: url.path)))
}

@Test func aFileEditedSinceIsNotUndone() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(titleEdit, to: [url.path]), [url])
    let edited = try Data(contentsOf: url)
    expectChanged(
        scratchWriter().write(TagEdit(values: [.album: "Elsewhere"]), to: [url.path]), [url])
    let report = writer.undoLast()
    #expect(report.failures.map(\.kind) == [.changedSinceEdit])
    #expect(try Data(contentsOf: url) != edited)
    #expect(try tags(url).album == "Elsewhere")
    #expect(writer.undoLast().nothingToUndo)
}

@Test func aBatchIsOneUndoAndEachFileFailsAlone() throws {
    let urls = try [Sample.mp4, .mp3v24, .flac, .aiffV23].map { try $0.copy() }
    let originals = try urls.map { try Data(contentsOf: $0) }
    let missing = urls[0].deletingLastPathComponent().appendingPathComponent("gone.mp3")
    let writer = scratchWriter()
    let report = writer.write(
        TagEdit(values: [.album: "Batch"]), to: urls.map(\.path) + [missing.path])
    #expect(report.changed == urls.map(\.path))
    #expect(report.failures.map(\.path) == [missing.path])
    for url in urls { #expect(try tags(url).album == "Batch") }
    expectChanged(writer.undoLast(), urls.reversed())
    #expect(try urls.map { try Data(contentsOf: $0) } == originals)
}

@Test func anEditThatChangesNothingDoesntWrite() throws {
    let url = try Sample.mp3v24.copy()
    let before = try FileManager.default.attributesOfItem(atPath: url.path)
    let title = try tags(url).title ?? ""
    let report = scratchWriter().write(TagEdit(values: [.title: title]), to: [url.path])
    #expect(report.unchanged == [url.path])
    let after = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
    #expect(after[.systemFileNumber] as? Int == before[.systemFileNumber] as? Int)
}

@Test func id3v22IsRefused() throws {
    let (root, manifest) = try fixtureLibrary.get()
    let file = try #require(manifest.files.first { $0.tagFormats == [.id3v22] })
    let url = try scratchCopy(of: root.appendingPathComponent(file.path))
    let original = try Data(contentsOf: url)
    let report = scratchWriter().write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.unsupported])
    #expect(try Data(contentsOf: url) == original)
}

@Test func badValuesAreRefusedBeforeWriting() throws {
    let url = try Sample.mp4.copy()
    let original = try Data(contentsOf: url)
    for edit in [
        TagEdit(values: [.trackNumber: "3a"]), TagEdit(values: [.discTotal: "70000"]),
        TagEdit(values: [.compilation: "yes"]), TagEdit(values: [.title: "a\u{0}b"]),
        TagEdit(art: .replace(Data([1, 2, 3]), mimeType: "image/gif")),
    ] {
        #expect(scratchWriter().write(edit, to: [url.path]).failures.map(\.kind) == [.invalidValue])
    }
    #expect(try Data(contentsOf: url) == original)
}

@Test(arguments: [Sample.mp4, .mp3v24, .flac, .aiffV24])
func theFileKeepsItsAttributes(_ sample: Sample) throws {
    let url = try sample.copy()
    let path = url.path
    chmod(path, 0o700)
    #expect(setxattr(path, "com.example.note", "kept", 4, 0, 0) == 0)
    try (url as NSURL).setResourceValue(["Red", "Music"], forKey: .tagNamesKey)
    let created = Date(timeIntervalSince1970: 1_000_000_000)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: path)
    chflags(path, UInt32(UF_HIDDEN))
    defer { chflags(path, 0) }
    let before = try attributes(path)
    let writer = scratchWriter()
    // Once in place, once past the padding, so both the clone and the full copy are covered.
    for title in ["A", String(repeating: "B", count: 70_000)] {
        expectChanged(writer.write(TagEdit(values: [.title: title]), to: [path]), [url])
        #expect(try attributes(path) == before)
    }
    expectChanged(writer.undoLast(), [url])
    #expect(try attributes(path) == before)
}

/// Everything but the data and the times that change with it.
private func attributes(_ path: String) throws -> [String] {
    var info = stat()
    #expect(lstat(path, &info) == 0)
    var names = [CChar](repeating: 0, count: 4096)
    let length = listxattr(path, &names, names.count, 0)
    let xattrs = String(
        decoding: names[0..<max(0, length)].map { UInt8(bitPattern: $0) }, as: UTF8.self
    )
    .split(separator: "\0").sorted().map { name -> String in
        var value = [UInt8](repeating: 0, count: 4096)
        let count = getxattr(path, String(name), &value, value.count, 0, 0)
        return "\(name)=\(value.prefix(max(0, count)))"
    }
    return [
        "mode \(String(info.st_mode, radix: 8))", "flags \(info.st_flags)",
        "uid \(info.st_uid)", "created \(info.st_birthtimespec.tv_sec)",
    ] + xattrs
}

@Test func aFileWithAnotherHardLinkIsRefused() throws {
    let url = try Sample.mp3v24.copy()
    let original = try Data(contentsOf: url)
    let other = url.path + " link"
    #expect(link(url.path, other) == 0)
    let report = scratchWriter().write(titleEdit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.unsupported])
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: URL(fileURLWithPath: other)) == original)
}

@Test func aFrameOverID3sLimitIsRefusedNotTrapped() {
    #expect(throws: ParseFailure.self) {
        try ID3Frame(id: "APIC", body: [UInt8](repeating: 0, count: 1 << 28), version: 4)
    }
    #expect(throws: ParseFailure.self) {
        try ID3Frame(id: "APIC", body: [UInt8](repeating: 0, count: 1 << 28), version: 3)
    }
}

/// 2.3 has no flag 0x08; 2.4 uses it for compression.
@Test func commentFlagsAreReadPerVersion() throws {
    var frame = try ID3Frame(
        id: "COMM", body: [0] + Array("eng".utf8) + [0] + Array("Hi".utf8), version: 3)
    frame.raw[9] = 0x08
    #expect(frame.isUserComment(version: 3))
    #expect(!frame.isUserComment(version: 4))
    frame.raw[9] = 0x40
    #expect(!frame.isUserComment(version: 3), "encrypted in 2.3")
    #expect(!frame.isUserComment(version: 4), "grouped in 2.4")
}
