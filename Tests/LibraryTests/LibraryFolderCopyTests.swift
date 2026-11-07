import Foundation
import Testing

@testable import Library

/// A temporary folder with a `Library` folder and an `Incoming` one holding a tagged FLAC.
private func copyFolders() throws -> (library: String, source: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-folder-\(UUID().uuidString)")
    let library = directory.appendingPathComponent("Library")
    let incoming = directory.appendingPathComponent("Incoming")
    for folder in [library, incoming] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let source = incoming.appendingPathComponent("rip.flac")
    try taggedFLAC(tags: [
        "TITLE": "Song", "ARTIST": "Artist", "ALBUMARTIST": "Band", "ALBUM": "Album",
        "TRACKNUMBER": "2", "DISCNUMBER": "1", "DISCTOTAL": "2",
    ]).write(to: source)
    return (library.path, source.path)
}

@Test func aCopyGoesWhereItsTagsPutItAndLeavesTheOriginal() throws {
    let (library, source) = try copyFolders()
    let before = try FileManager.default.attributesOfItem(atPath: source)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: source, isDirectory: false))

    let copy = try copyIntoLibraryFolder(source, libraryFolder: library)

    #expect(copy == library + "/Band/Album/1-02 Song.flac")
    #expect(try Data(contentsOf: URL(fileURLWithPath: copy, isDirectory: false)) == bytes)
    #expect(try Data(contentsOf: URL(fileURLWithPath: source, isDirectory: false)) == bytes)
    let after = try FileManager.default.attributesOfItem(atPath: source)
    #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
}

@Test func aFileAlreadyAtTheCopysPathIsKeptAndTheCopyRefused() throws {
    let (library, source) = try copyFolders()
    let copy = try copyIntoLibraryFolder(source, libraryFolder: library)
    let other = Data("not the same file".utf8)
    try other.write(to: URL(fileURLWithPath: copy, isDirectory: false))

    #expect(throws: CopyError.alreadyThere(source, copy)) {
        try copyIntoLibraryFolder(source, libraryFolder: library)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: copy, isDirectory: false)) == other)
}

@Test func aFileWhoseTagsDontReadIsntCopied() throws {
    let (library, source) = try copyFolders()
    try Data("not audio".utf8).write(to: URL(fileURLWithPath: source, isDirectory: false))

    #expect {
        try copyIntoLibraryFolder(source, libraryFolder: library)
    } throws: { error in
        guard case .unreadable(source, _) = error as? CopyError else { return false }
        return true
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: library).isEmpty)
}
