import Foundation
import Testing

@testable import Library

/// A folder holding "a.flac", removed with the folder.
private final class Folder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
    var file: URL { url.appendingPathComponent("a.flac", isDirectory: false) }

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("flac".utf8)))
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

/// A file a share with no Trash won't let go of is reported, and stays. Root writes into a
/// read-only folder, so the test needs another user.
@Test(.enabled(if: geteuid() != 0, "root ignores a read-only folder"))
func aFileThatCantBeDeletedOnAShareWithNoTrashIsReported() async throws {
    let folder = try Folder()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
    let failure = await trashOrDelete([folder.file]) { _ in throw CocoaError(.featureUnsupported) }
    let reported = try #require(failure)
    #expect(reported.hasPrefix(folder.file.path + ": "))
    #expect(FileManager.default.fileExists(atPath: folder.file.path))
}

/// Only a volume with no Trash makes it a delete; the Trash refusing a file for another reason
/// leaves it where it is.
@Test func aTrashThatRefusesForAnotherReasonDeletesNothing() async throws {
    let folder = try Folder()
    let refusing: @Sendable (URL) throws -> Void = { _ in
        throw CocoaError(.fileWriteNoPermission)
    }
    let failure = await trashOrDelete([folder.file], trashItem: refusing)
    #expect(failure?.hasPrefix(folder.file.path + ": ") == true)
    #expect(FileManager.default.fileExists(atPath: folder.file.path))
}

@Test func nothingToReportWhenEveryFileGoes() async throws {
    let folder = try Folder()
    #expect(
        await trashOrDelete([folder.file]) { _ in throw CocoaError(.featureUnsupported) } == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.file.path))
}

/// The share's no-Trash error may come as POSIX `ENOTSUP`, given as is or underlying a Cocoa
/// error; each deletes the file.
@Test(arguments: [
    POSIXError(.ENOTSUP) as NSError,
    NSError(
        domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
        userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOTSUP) as NSError]),
])
func aShareWithNoTrashSayingSoAnotherWayDeletesTheFile(_ noTrash: NSError) async throws {
    let folder = try Folder()
    let failure = await trashOrDelete([folder.file]) { _ in throw noTrash }
    #expect(failure == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.file.path))
}
