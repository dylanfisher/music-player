import Foundation
import Settings

@testable import Fixtures
@testable import Library

/// A few fixture files, generated once for the target, apart from the other targets' copies.
private let sourceMusic = Result { () throws -> URL in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/snapshot-tests")
    _ = try generateFixtures(count: 6, in: root)
    return root
}

/// A data folder of its own in a fresh temporary directory, its index scanned from a copy of
/// the fixtures, with one play recorded, and a snapshot folder beside it.
struct SnapshotTestLibrary {
    let directory: URL
    let databaseURL: URL
    let snapshotFolder: URL
    /// The file whose play is recorded.
    let played: String

    /// Seconds since 1970 of the play recorded.
    static let playedAt = 1_800_000_000.0

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString)")
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try sourceMusic.get(), to: music)
        databaseURL = libraryFileURL(in: directory)
        snapshotFolder = directory.appendingPathComponent("Backups", isDirectory: true)
        _ = try LibraryScanner(databaseURL: databaseURL).scan(
            WatchedFolder(path: music.path, kind: .local))
        // A play counts for any path, held by the index or not.
        played = music.appendingPathComponent("played.flac", isDirectory: false).path
        try LibraryIndex(at: databaseURL).recordPlay(played, at: Self.playedAt)
    }

    func index() throws -> LibraryIndex { try LibraryIndex(at: databaseURL) }
}

/// The plays the index at `url` holds over all time, and its tracks.
func counts(_ index: LibraryIndex) throws -> (tracks: Int, plays: Int) {
    (try index.trackCount(), try index.playCount(in: PlaySpan(start: 0, end: .max)))
}
