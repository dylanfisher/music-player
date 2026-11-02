import Foundation
import Settings
import Testing

@testable import Fixtures
@testable import Library

/// A small fixture library scanned into a database of its own, once per test run. Tests only
/// read it.
let browserLibrary = Result { () throws -> (root: String, databaseURL: URL) in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/library-browser-tests")
    _ = try generateFixtures(count: 120, in: root)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("library-browser-\(UUID().uuidString)")
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    _ = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: root.path, kind: .local))
    return (root.path, databaseURL)
}

/// A copy of the browser library's database in a fresh temporary folder, for a test that writes
/// playlists or stats.
func writableBrowserDatabase() throws -> URL {
    let source = try browserLibrary.get().databaseURL
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("playlist-browser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: source.path + suffix) {
        try FileManager.default.copyItem(
            atPath: source.path + suffix, toPath: databaseURL.path + suffix)
    }
    return databaseURL
}

/// Waits up to 10 seconds for `condition`, then records what it saw.
@MainActor
func waitFor(_ what: String, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while try await !condition() {
        guard Date() < deadline else {
            Issue.record("timed out waiting for \(what)")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
