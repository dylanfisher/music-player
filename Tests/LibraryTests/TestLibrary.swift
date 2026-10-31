import Foundation
import Testing

@testable import Fixtures
@testable import Library
@testable import Settings

/// A small fixture library of its own, apart from the other test targets' copies, since the
/// targets run in one process. It holds every malformation once.
let sourceLibrary = Result { () throws -> (URL, FixtureManifest) in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/library-tests")
    _ = try generateFixtures(count: 40, in: root)
    return (root, try loadManifest(in: root))
}

/// A copy of the source library in a fresh temporary directory, with its own database, so a
/// test can change files freely.
struct TestLibrary {
    var root: String
    var databaseURL: URL
    var manifest: FixtureManifest

    init() throws {
        let (source, manifest) = try sourceLibrary.get()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("Music")
        try FileManager.default.copyItem(at: source, to: root)
        self.root = root.path
        databaseURL = directory.appendingPathComponent("library.sqlite")
        self.manifest = manifest
    }

    var folder: WatchedFolder { WatchedFolder(path: root, kind: .local) }
    var scanner: LibraryScanner { LibraryScanner(databaseURL: databaseURL) }

    func scan(
        _ folder: WatchedFolder? = nil, only subtrees: [String] = [],
        control: ScanControl = ScanControl()
    ) throws -> ScanSummary {
        try scanner.scan(folder ?? self.folder, only: subtrees, control: control)
    }

    func index() throws -> LibraryIndex { try LibraryIndex(at: databaseURL) }

    func path(_ file: FixtureFile) -> String { root + "/" + file.path }

    /// Files tag reading fails on, because their structure is broken.
    var unreadableFiles: [FixtureFile] {
        manifest.files.filter { file in
            guard let malformation = file.malformation else { return false }
            return malformation != .truncated && !malformation.isFieldLevel
        }
    }

    var readableCount: Int { manifest.files.count - unreadableFiles.count }
}
