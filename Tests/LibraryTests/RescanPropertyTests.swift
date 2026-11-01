import Fixtures
import Foundation
import Testing

@testable import Library
@testable import Settings

/// What an index holds for each path under `root`, without the row IDs and dates a fresh index
/// hands out again.
private func contents(_ databaseURL: URL, under root: String) throws -> [String: String] {
    let index = try LibraryIndex(at: databaseURL)
    let known = try index.knownFiles(under: root)
    let rows = try index.rows(ids: known.values.filter(\.hasTrack).map(\.id))
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    return known.mapValues { file in
        var row = byID[file.id]
        row?.id = 0
        row?.albumID = nil
        row?.addedSeconds = 0
        return "\(file.sizeBytes) \(file.modifiedSeconds) \(String(describing: file.failure)) "
            + String(describing: row)
    }
}

/// A random file tree, changed at random between rescans, full or of the changed folders as the
/// watcher reports them. After each, the index must hold what a full scan of the tree into a new
/// index holds.
@Test func randomTreeChangesRescanToWhatAFullScanFinds() throws {
    let (source, manifest) = try sourceLibrary.get()
    let sources = manifest.files.map { source.appendingPathComponent($0.path) }
    try forEachPropertyCase("rescans") { random in
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rescan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Music").path
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let scanner = LibraryScanner(databaseURL: databaseURL)
        let folder = WatchedFolder(path: root, kind: .local)
        let files = FileManager.default
        var folders = [root]
        var paths: [String] = []
        var next = 0
        var mtime = Date(timeIntervalSince1970: 1_700_000_000)
        func newName() -> String {
            next += 1
            return "f\(next)"
        }
        func addFolder(_ changed: inout Set<String>) throws {
            let parent = random.pick(folders)
            let path = parent + "/" + newName()
            try files.createDirectory(atPath: path, withIntermediateDirectories: false)
            folders.append(path)
            changed.insert(parent)
        }
        func addFile(_ changed: inout Set<String>) throws {
            let from = random.pick(sources)
            let parent = random.pick(folders)
            let path = parent + "/" + newName() + "." + from.pathExtension
            try files.copyItem(atPath: from.path, toPath: path)
            paths.append(path)
            changed.insert(parent)
        }
        /// A new modification time, as an edit gives, so the change is seen by (size, mtime).
        func touch(_ path: String) throws {
            mtime += 60
            try files.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }
        func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

        try files.createDirectory(atPath: root, withIntermediateDirectories: true)
        var ignored = Set<String>()
        for _ in 0..<Int.random(in: 0...3, using: &random) { try addFolder(&ignored) }
        for _ in 0..<Int.random(in: 1...10, using: &random) { try addFile(&ignored) }
        _ = try scanner.scan(folder)

        for round in 0..<Int.random(in: 1...3, using: &random) {
            var changed = Set<String>()
            for _ in 0..<Int.random(in: 1...5, using: &random) {
                switch Int.random(in: 0..<8, using: &random) {
                case 0: try addFile(&changed)
                case 1: try addFolder(&changed)
                case 2 where !paths.isEmpty:
                    let path = paths.remove(at: Int.random(in: 0..<paths.count, using: &random))
                    try files.removeItem(atPath: path)
                    changed.insert(parent(path))
                case 3 where !paths.isEmpty:
                    let index = Int.random(in: 0..<paths.count, using: &random)
                    let to =
                        random.pick(folders) + "/" + newName() + "."
                        + (paths[index] as NSString).pathExtension
                    try files.moveItem(atPath: paths[index], toPath: to)
                    changed.formUnion([parent(paths[index]), parent(to)])
                    paths[index] = to
                case 4 where !paths.isEmpty:
                    // New content under the same name.
                    let path = random.pick(paths)
                    try files.removeItem(atPath: path)
                    try files.copyItem(atPath: random.pick(sources).path, toPath: path)
                    try touch(path)
                    changed.insert(parent(path))
                case 5 where !paths.isEmpty:
                    let path = random.pick(paths)
                    try touch(path)
                    changed.insert(parent(path))
                case 6 where folders.count > 1:
                    let gone = folders[Int.random(in: 1..<folders.count, using: &random)]
                    try files.removeItem(atPath: gone)
                    folders.removeAll { $0 == gone || $0.hasPrefix(gone + "/") }
                    paths.removeAll { $0.hasPrefix(gone + "/") }
                    changed.formUnion([gone, parent(gone)])
                case 7 where folders.count > 1:
                    let old = folders[Int.random(in: 1..<folders.count, using: &random)]
                    let new = parent(old) + "/" + newName()
                    try files.moveItem(atPath: old, toPath: new)
                    func renamed(_ path: String) -> String {
                        path == old || path.hasPrefix(old + "/")
                            ? new + path.dropFirst(old.count) : path
                    }
                    folders = folders.map(renamed)
                    paths = paths.map(renamed)
                    changed.formUnion([old, new, parent(old)])
                default: try addFile(&changed)
                }
            }
            let subtrees = random.chance(0.5) ? Array(changed).sorted() : []
            let before = try contents(databaseURL, under: root)
            _ = try scanner.scan(folder, only: subtrees)
            // A root that lists nothing is taken for an unmounted volume and removes nothing
            // (ADR 0009), so the index keeps what it had.
            if try files.contentsOfDirectory(atPath: root).isEmpty {
                try #require(try contents(databaseURL, under: root) == before, "round \(round)")
                continue
            }

            let fresh = directory.appendingPathComponent("fresh-\(round).sqlite")
            _ = try LibraryScanner(databaseURL: fresh).scan(folder)
            let expected = try contents(fresh, under: root)
            try #require(Set(expected.keys) == Set(paths), "round \(round): the full scan's files")
            let indexed = try contents(databaseURL, under: root)
            for path in Set(expected.keys).union(indexed.keys).sorted() {
                try #require(
                    indexed[path] == expected[path],
                    "round \(round), \(subtrees.isEmpty ? "full" : "subtree \(subtrees)") rescan: \(path)"
                )
            }
        }
    }
}
