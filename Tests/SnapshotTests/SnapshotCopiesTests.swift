import Foundation
import Testing

@testable import Library
@testable import Snapshot

/// The text of the file at `url`.
private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

/// The file at `url`'s permission bits.
private func mode(_ url: URL) throws -> Int {
    try #require(
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

/// `name`'s copy of `part` in `library`'s snapshot folder.
private func copy(_ part: SnapshotPart, of name: SnapshotName, in library: SnapshotTestLibrary)
    -> URL
{
    library.snapshotFolder.appendingPathComponent(name.fileName(of: part), isDirectory: false)
}

@Test func aSnapshotKeepsTheStateFileAndTheConfigFileWithoutItsSecrets() throws {
    let library = try SnapshotTestLibrary()
    let date = Date().addingTimeInterval(-86_400)
    try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: date)
    let name = SnapshotName(of: date)
    #expect(try text(copy(.state, of: name, in: library)) == stateText)
    let config = copy(.config, of: name, in: library)
    let kept = try text(config)
    #expect(!kept.contains(fakeDiscogsToken))
    #expect(!kept.contains(fakeServiceToken))
    #expect(!kept.contains("token"))
    #expect(kept == "{\n  \"library.groupByAlbumArtist\": false\n}\n")
    #expect(try mode(config) == 0o600)
    // The live file is as it was.
    #expect(try text(library.paths.configFile) == configWithTokens)
}

/// No state file is no copy, not a failure; a config file that isn't JSON isn't copied at
/// all, and the day's earlier copies go, so the snapshot keeps only what its own write copied.
@Test func aMissingOrUnreadableFileIsLeftOutOfTheSnapshot() throws {
    let library = try SnapshotTestLibrary()
    let date = Date().addingTimeInterval(-86_400)
    let name = SnapshotName(of: date)
    try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: date)
    try FileManager.default.removeItem(at: library.paths.stateFile)
    try Data("{ \"discogs.token\": \"\(fakeDiscogsToken)\" ".utf8).write(
        to: library.paths.configFile)
    try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: date)
    let names = try FileManager.default.contentsOfDirectory(atPath: library.snapshotFolder.path)
    #expect(names == [name.fileName])
}

/// Snapshot, change the state, the settings and the tokens, restore: the next launch has the
/// snapshot's state and settings, with the tokens as they were just before it.
@Test func aRestorePutsBackTheStateAndSettingsAndKeepsTheTokens() throws {
    let library = try SnapshotTestLibrary()
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder,
        on: Date().addingTimeInterval(-86_400))
    let changedState = #"{"window.sidebarWidth": 400}"#
    try Data(changedState.utf8).write(to: library.paths.stateFile)
    let live = """
        {
          "library.groupByAlbumArtist": true,
          "recommender.token": "\(fakeServiceToken)-new"
        }

        """
    try Data(live.utf8).write(to: library.paths.configFile)

    try prepareRestore(
        of: snapshot, paths: library.paths, snapshotFolder: library.snapshotFolder, now: Date())
    // Nothing is replaced until the next launch.
    #expect(try text(library.paths.stateFile) == changedState)
    #expect(try text(library.paths.configFile) == live)
    // The files before the restore are kept with the index's snapshot, the config's stripped.
    let before = try #require(
        try snapshots(in: library.snapshotFolder).first(where: \.isBeforeRestore))
    #expect(try text(copy(.state, of: before.name, in: library)) == changedState)
    let beforeConfig = try text(copy(.config, of: before.name, in: library))
    #expect(beforeConfig.contains("\"library.groupByAlbumArtist\": true"))
    #expect(!beforeConfig.contains(fakeServiceToken))

    #expect(try applyPendingRestore(paths: library.paths) == .applied(snapshot.lastPathComponent))
    #expect(try text(library.paths.stateFile) == stateText)
    let restored = try text(library.paths.configFile)
    #expect(restored.contains("\"library.groupByAlbumArtist\": false"))
    #expect(restored.contains("\"recommender.token\": \"\(fakeServiceToken)-new\""))
    #expect(!restored.contains(fakeDiscogsToken))
    #expect(try mode(library.paths.configFile) == 0o600)
    let left = try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
    #expect(!left.contains { $0.hasSuffix(".restoring") || $0.hasSuffix(".partial") })
}

/// A snapshot without copies, as one from before they were kept, restores the index only.
@Test func aSnapshotWithoutCopiesLeavesTheFilesAsTheyAre() throws {
    let library = try SnapshotTestLibrary()
    let date = Date().addingTimeInterval(-86_400)
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder, on: date)
    for part in SnapshotPart.allCases {
        try FileManager.default.removeItem(at: copy(part, of: SnapshotName(of: date), in: library))
    }
    let before = try counts(library.index())
    try library.index().recordPlay(library.played, at: SnapshotTestLibrary.playedAt + 60)
    let changedState = #"{"window.sidebarWidth": 400}"#
    try Data(changedState.utf8).write(to: library.paths.stateFile)

    try prepareRestore(
        of: snapshot, paths: library.paths, snapshotFolder: library.snapshotFolder, now: Date())
    _ = try applyPendingRestore(paths: library.paths)
    #expect(try counts(library.index()) == before)
    #expect(try text(library.paths.stateFile) == changedState)
    #expect(try text(library.paths.configFile) == configWithTokens)
}

/// A live config file whose tokens can't be read refuses the restore, with nothing pending.
@Test func aConfigFileThatDoesntReadStopsTheRestore() throws {
    let library = try SnapshotTestLibrary()
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder,
        on: Date().addingTimeInterval(-86_400))
    let broken = "{ \"discogs.token\": "
    try Data(broken.utf8).write(to: library.paths.configFile)
    #expect {
        try prepareRestore(
            of: snapshot, paths: library.paths, snapshotFolder: library.snapshotFolder,
            now: Date())
    } throws: { error in
        guard case SnapshotError.configNotKept(let path, _) = error else { return false }
        return path == library.paths.configFile.path
    }
    let left = try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
    #expect(!left.contains { $0.hasSuffix(".restoring") || $0 == "restore.pending" })
    #expect(try applyPendingRestore(paths: library.paths) == .none)
    #expect(try text(library.paths.configFile) == broken)
}

/// The config file breaks between Restore… and the launch: nothing moves, and the restore
/// waits until the file reads.
@Test func aConfigFileThatBreaksBeforeTheLaunchLeavesTheRestoreWaiting() throws {
    let library = try SnapshotTestLibrary()
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder,
        on: Date().addingTimeInterval(-86_400))
    let before = try counts(library.index())
    try library.index().recordPlay(library.played, at: SnapshotTestLibrary.playedAt + 60)
    try prepareRestore(
        of: snapshot, paths: library.paths, snapshotFolder: library.snapshotFolder, now: Date())
    try Data("{".utf8).write(to: library.paths.configFile)
    #expect(throws: SnapshotError.self) { try applyPendingRestore(paths: library.paths) }
    #expect(try counts(library.index()).plays == before.plays + 1)
    #expect(try text(library.paths.configFile) == "{")

    try Data(configWithTokens.utf8).write(to: library.paths.configFile)
    #expect(try applyPendingRestore(paths: library.paths) == .applied(snapshot.lastPathComponent))
    #expect(try counts(library.index()) == before)
    #expect(try text(library.paths.configFile).contains(fakeServiceToken))
}

/// A launch stopped after the index's swap, before the files moved: the next one moves them.
@Test func filesLeftByALaunchStoppedPartwayAreMovedAtTheNext() throws {
    let library = try SnapshotTestLibrary()
    let snapshot = try writeSnapshot(
        of: library.index(), keeping: library.paths, into: library.snapshotFolder,
        on: Date().addingTimeInterval(-86_400))
    try Data(#"{"window.sidebarWidth": 400}"#.utf8).write(to: library.paths.stateFile)
    try prepareRestore(
        of: snapshot, paths: library.paths, snapshotFolder: library.snapshotFolder, now: Date())
    let restoring = URL(fileURLWithPath: library.databaseURL.path + ".restoring")
    try LibraryIndex.move(library.databaseURL, to: library.directory.appendingPathComponent("old"))
    try LibraryIndex.move(restoring, to: library.databaseURL)
    #expect(try applyPendingRestore(paths: library.paths) == .applied(snapshot.lastPathComponent))
    #expect(try text(library.paths.stateFile) == stateText)
}
