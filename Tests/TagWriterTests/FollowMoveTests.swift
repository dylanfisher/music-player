import Darwin
import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

/// `url` renamed into a new folder beside it, as Keep Files Organized renames a file.
private func moved(_ url: URL) throws -> URL {
    let folder = url.deletingLastPathComponent().appendingPathComponent("Artist/Album")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let new = folder.appendingPathComponent("01 One." + url.pathExtension)
    try FileManager.default.moveItem(at: url, to: new)
    return new
}

@Test func undoFindsAFileItsRecordsFollowedToItsNewPath() throws {
    let url = try Sample.flac.copy()
    let before = try tags(url)
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    let new = try moved(url)
    #expect(writer.follow([(url.path, new.path)]).isEmpty)
    expectChanged(writer.undoLast(), [new])
    #expect(try tags(new) == before)
}

@Test func withoutFollowingTheUndoDoesntFindTheMovedFile() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    let new = try moved(url)
    let report = writer.undoLast()
    #expect(report.changed.isEmpty)
    #expect(!report.failures.isEmpty)
    #expect(try tags(new).title == "One")
}

@Test func twoEditsOfAMovedFileUndoOneAfterTheOther() throws {
    let url = try Sample.mp3v24.copy()
    let before = try tags(url)
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    expectChanged(writer.write(TagEdit(values: [.title: "Two"]), to: [url.path]), [url])
    let new = try moved(url)
    #expect(writer.follow([(url.path, new.path)]).isEmpty)
    expectChanged(writer.undoLast(), [new])
    #expect(try tags(new).title == "One")
    expectChanged(writer.undoLast(), [new])
    #expect(try tags(new) == before)
}

@Test func aMoveThatGaveTheFileANewInodeIsStillFollowed() throws {
    let url = try Sample.flac.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.title: "One"]), to: [url.path]), [url])
    // As a share may renumber a renamed file: a copy with the same bytes and mtime.
    var info = stat()
    #expect(lstat(url.path, &info) == 0)
    let new = url.deletingLastPathComponent().appendingPathComponent("01 One.flac")
    try FileManager.default.copyItem(at: url, to: new)
    try FileManager.default.removeItem(at: url)
    var times = [info.st_atimespec, info.st_mtimespec]
    #expect(utimensat(AT_FDCWD, new.path, &times, 0) == 0)
    var copied = stat()
    #expect(lstat(new.path, &copied) == 0)
    #expect(copied.st_ino != info.st_ino)

    #expect(writer.follow([(url.path, new.path)]).isEmpty)
    expectChanged(writer.undoLast(), [new])
}

@Test func followingAFileThatIsntThereFailsLoudly() throws {
    let writer = scratchWriter()
    let failures = writer.follow([("/nowhere/a.flac", "/nowhere/b.flac")])
    #expect(failures.count == 1)
}
