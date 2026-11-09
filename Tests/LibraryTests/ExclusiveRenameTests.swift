import Darwin
import Foundation
import Testing

@testable import Library

/// A temporary folder with a source file to rename, and calls that stand in for a share that
/// refuses `RENAME_EXCL`, so every rename takes the fallback.
private final class FallbackFolder {
    let root: String
    var calls = MoveCalls()

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("exclusive-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: URL(fileURLWithPath: source, isDirectory: false))
        calls.renameExclusive = { _, _ in ENOTSUP }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    var source: String { root + "/source.flac" }
    var destination: String { root + "/01 Song.flac" }

    func contents(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false))
    }
}

/// Makes a new file at `path` the way another Mac running this app takes a name: an exclusive
/// create, which the server refuses when the name is taken. True when it made one.
private func anotherClientTakes(_ path: String) -> Bool {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    guard descriptor >= 0 else { return false }
    _ = write(descriptor, "other", 5)
    close(descriptor)
    return true
}

@Test func anotherClientCantTakeTheNameBetweenTheCheckAndTheRename() throws {
    let folder = try FallbackFolder()
    let destination = folder.destination
    folder.calls.rename = { from, to in
        // Another Mac, between this Mac's check and its rename.
        #expect(!anotherClientTakes(destination), "the name wasn't held across clients")
        return Darwin.rename(from, to) == 0 ? 0 : errno
    }
    #expect(renameNeverOver(folder.source, to: destination, folder.calls) == 0)
    #expect(try folder.contents(destination) == Data("source".utf8))
    #expect(!FileManager.default.fileExists(atPath: folder.source))
}

@Test func aNameAnotherClientTookFirstIsTaken() throws {
    let folder = try FallbackFolder()
    #expect(anotherClientTakes(folder.destination))
    folder.calls.rename = { _, _ in
        Issue.record("renamed onto a taken name")
        return 0
    }
    #expect(renameNeverOver(folder.source, to: folder.destination, folder.calls) == EEXIST)
    #expect(try folder.contents(folder.destination) == Data("other".utf8))
    #expect(FileManager.default.fileExists(atPath: folder.source))
}

@Test func aFailedRenameRemovesTheEmptyFileThatReservedTheName() throws {
    let folder = try FallbackFolder()
    folder.calls.rename = { _, _ in EIO }
    #expect(renameNeverOver(folder.source, to: folder.destination, folder.calls) == EIO)
    #expect(!FileManager.default.fileExists(atPath: folder.destination))
    #expect(try folder.contents(folder.source) == Data("source".utf8))
}

@Test func aFailedRenameLeavesAFileThatReplacedTheReservation() throws {
    let folder = try FallbackFolder()
    let destination = folder.destination
    let root = folder.root
    folder.calls.rename = { _, to in
        // Another client's plain rename onto the empty file, then this rename fails.
        let other = root + "/other.flac"
        try? Data("other".utf8).write(to: URL(fileURLWithPath: other, isDirectory: false))
        _ = Darwin.rename(other, to)
        return EIO
    }
    #expect(renameNeverOver(folder.source, to: destination, folder.calls) == EIO)
    #expect(try folder.contents(destination) == Data("other".utf8))
}

@Test func anEmptyFileACrashLeftAtTheNameIsATakenName() throws {
    let folder = try FallbackFolder()
    #expect(FileManager.default.createFile(atPath: folder.destination, contents: Data()))
    #expect(renameNeverOver(folder.source, to: folder.destination, folder.calls) == EEXIST)
    #expect(FileManager.default.fileExists(atPath: folder.destination))
    #expect(FileManager.default.fileExists(atPath: folder.source))
}
