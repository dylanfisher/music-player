import Foundation
import Settings

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
