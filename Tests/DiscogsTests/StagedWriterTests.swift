import Foundation
import Testing

@testable import Discogs
@testable import Fixtures
@testable import Library
@testable import Metadata
@testable import Recommender
@testable import Settings
@testable import TagWriter

// StagedWriter on generated fixtures in a temporary staging folder beside a temporary library
// folder; nothing else is written.

/// The entries a journal holds.
private func entries(_ journal: TagUndoJournal) throws -> [String] {
    guard FileManager.default.fileExists(atPath: journal.directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: journal.directory.path)
        .filter { !$0.hasPrefix(".") }.sorted()
}

@Test func aCleanRunIsWrittenAndReadsBackWithNothingToChange() async throws {
    let setup = try StagedSetup()
    let run = try await setup.run(exactStaging)
    try #require(run.verdict == .clean)
    let writer = setup.stagedWriter
    #expect(writer.write(run, mapping: setup.mapping) == .clean)
    let again = try await setup.autoTag()
    #expect(again.verdict == .clean)
    #expect(again.changes?.files.flatMap(\.changes) == [])
    #expect(try entries(writer.writer.journal).count == 1)
}

@Test func aPathOutsideTheStagingFolderIsRefusedAndNothingIsWritten() async throws {
    let setup = try StagedSetup()
    var run = try await setup.run(exactStaging)
    let outside = try setup.libraryFile()
    let before = try Data(contentsOf: URL(fileURLWithPath: outside, isDirectory: false))
    run.edits.append((outside, run.edits[0].edit))
    let staged = try Data(contentsOf: URL(fileURLWithPath: run.edits[0].path, isDirectory: false))
    #expect(
        setup.stagedWriter.write(run, mapping: setup.mapping)
            == .error(["\(outside) isn't inside the staging folder \(setup.root.path)"]))
    #expect(try Data(contentsOf: URL(fileURLWithPath: outside, isDirectory: false)) == before)
    #expect(
        try Data(contentsOf: URL(fileURLWithPath: run.edits[0].path, isDirectory: false))
            == staged)
    #expect(throws: StagedPathRefused.self) { try setup.stagedWriter.write([run.edits.last!]) }
}

@Test func aLinkOutOfTheStagingFolderIsRefused() async throws {
    let setup = try StagedSetup()
    let outside = try setup.libraryFile()
    let link = setup.root.appendingPathComponent("job-7/link.flac", isDirectory: false).path
    try FileManager.default.createDirectory(
        at: setup.root.appendingPathComponent("job-7", isDirectory: true),
        withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
    #expect(setup.stagedWriter.refusedPath([link]) == link)
    #expect(setup.stagedWriter.refusedPath([setup.root.path + "/job-7/../../x.flac"]) != nil)
}

@Test func undoAfterAStagedWriteRevertsTheLibraryEditBeforeIt() async throws {
    let setup = try StagedSetup()
    let library = try setup.libraryFile()
    let original = try Data(contentsOf: URL(fileURLWithPath: library, isDirectory: false))
    let main = TagWriter(
        journal: TagUndoJournal(
            dataDirectory: setup.dumps.directory.appendingPathComponent("data", isDirectory: true)))
    var edit = TagEdit()
    edit.values[.comment] = "edited in the library"
    #expect(main.write(edit, to: [library]).changed == [library])

    let run = try await setup.run(exactStaging)
    #expect(setup.stagedWriter.write(run, mapping: setup.mapping) == .clean)
    let written = try run.edits.map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) }
    #expect(try entries(main.journal).count == 1)

    let undo = main.undoLast()
    #expect(undo.failures == [])
    #expect(undo.changed == [library])
    #expect(try Data(contentsOf: URL(fileURLWithPath: library, isDirectory: false)) == original)
    #expect(try run.edits.map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) } == written)
    #expect(main.undoLast().nothingToUndo)
}

@Test func aStagedFileIsNeverInTheIndex() async throws {
    let setup = try StagedSetup()
    _ = try setup.libraryFile()
    let index = setup.dumps.directory.appendingPathComponent("library.sqlite")
    let scanner = LibraryScanner(databaseURL: index)
    let folder = WatchedFolder(path: setup.library.path, kind: .local)
    _ = try scanner.scan(folder)
    let run = try await setup.run(exactStaging)
    #expect(setup.stagedWriter.write(run, mapping: setup.mapping) == .clean)
    _ = try scanner.scan(folder)
    let paths = try LibraryIndex(at: index).database.prepare("SELECT path FROM files").map {
        try $0.text(0)
    }
    #expect(paths.count == 1)
    #expect(!paths.contains { $0.hasPrefix(setup.root.path) })
}
