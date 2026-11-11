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

/// The Trash's `featureUnsupported` underlying another error still means no Trash, and deletes.
@Test func noTrashUnderlyingAnotherErrorDeletesTheFile() async throws {
    let folder = try Folder()
    let noTrash = NSError(
        domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
        userInfo: [NSUnderlyingErrorKey: CocoaError(.featureUnsupported) as NSError])
    let failure = await trashOrDelete([folder.file]) { _ in throw noTrash }
    #expect(failure == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.file.path))
}

/// POSIX `ENOTSUP` can come from other failures than a missing Trash, so it deletes nothing,
/// given as is or underlying a Cocoa error.
@Test(arguments: [
    POSIXError(.ENOTSUP) as NSError,
    NSError(
        domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
        userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOTSUP) as NSError]),
])
func notSupportedFromTheTrashDeletesNothing(_ error: NSError) async throws {
    let folder = try Folder()
    let failure = await trashOrDelete([folder.file]) { _ in throw error }
    #expect(failure?.hasPrefix(folder.file.path + ": ") == true)
    #expect(FileManager.default.fileExists(atPath: folder.file.path))
}

/// A folder or a link in place of a file is never given to the Trash nor deleted, so neither
/// what's in the folder nor the link's target goes (ADR 0025, row 71).
@Test func onlyARegularFileIsRemoved() async throws {
    let folder = try Folder()
    let inner = folder.url.appendingPathComponent("folder.flac", isDirectory: true)
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
    let kept = inner.appendingPathComponent("kept.flac", isDirectory: false)
    #expect(FileManager.default.createFile(atPath: kept.path, contents: Data("flac".utf8)))
    let link = folder.url.appendingPathComponent("link.flac", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.file)
    let failure = await trashOrDelete([inner, link]) { url in
        Issue.record("\(url.path) was given to the Trash")
    }
    #expect(failure?.contains(inner.path + ": it isn't a regular file") == true)
    #expect(failure?.contains(link.path + ": it isn't a regular file") == true)
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(FileManager.default.fileExists(atPath: folder.file.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == folder.file.path)
}
