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

/// Stand-ins for the two secrets, never real ones.
let fakeDiscogsToken = "fakeDISCOGSfor3snapshot0nly"
let fakeServiceToken = "fake-service-token-for-snapshot-tests"

/// A config file with both secrets set, one of them twice, an old one commented out, and a
/// setting beside them.
let configWithTokens = """
    {
      // The Discogs token. Was "\(fakeDiscogsToken)-old".
      "discogs.token": "\(fakeDiscogsToken)",
      "library.groupByAlbumArtist": false,
      "recommender.token": "\(fakeServiceToken)",
      /* A copy: "\(fakeServiceToken)" */
      "discogs.token": "\(fakeDiscogsToken)",
    }

    """

/// A state file, as the app writes it.
let stateText = #"{"window.sidebarWidth": 240}"#

/// A data folder of its own in a fresh temporary directory, its index scanned from a copy of
/// the fixtures, with one play recorded, a state file and a config file holding both secrets,
/// and a snapshot folder beside it.
struct SnapshotTestLibrary {
    let directory: URL
    let paths: AppPaths
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
        paths = AppPaths(home: directory)
        try Data(stateText.utf8).write(to: paths.stateFile)
        try Data(configWithTokens.utf8).write(to: paths.configFile)
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
