import Darwin
import Foundation
import Library
import SQLite
import Settings
import TagWriter

/// Fills the disk image at `mount` under each file the app writes in turn, tries a write, and
/// returns every way one failed to be reported or changed something it shouldn't have. Each
/// target then gets its space back and must write again.
@MainActor
func fillEachTarget(_ mount: URL, music: MusicFolders) throws -> [String] {
    var failures: [String] = []
    failures += try database(on: mount, music: music).map { "database: \($0)" }
    failures += try stateFile(on: mount).map { "state file: \($0)" }
    failures += try configFile(on: mount).map { "config file: \($0)" }
    failures += try tagJournal(on: mount, music: music).map { "tag journal: \($0)" }
    return failures
}

/// A folder of its own on the image, made empty.
private func home(_ name: String, on mount: URL) throws -> URL {
    let home = mount.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: home.path) {
        try FileManager.default.removeItem(at: home)
    }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

/// Writes a file of zeros until the volume has no room left, down to its smallest block.
private func fill(_ mount: URL) throws -> URL {
    let filler = mount.appendingPathComponent("filler")
    let descriptor = open(filler.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    defer { close(descriptor) }
    for size in [1 << 20, 1 << 12, 512] {
        let chunk = [UInt8](repeating: 0, count: size)
        while write(descriptor, chunk, size) == size {}
        guard errno == ENOSPC else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }
    print("filled \(mount.path)", to: &standardError)
    return filler
}

/// A scan and a playlist edit with no room: each is rolled back whole and the database stays
/// sound.
private func database(on mount: URL, music: MusicFolders) throws -> [String] {
    let databaseURL = libraryFileURL(in: try home("database", on: mount))
    var failures: [String] = []
    let half = WatchedFolder(path: music.scan.path, kind: .local, exclude: [evenTracks])
    let whole = WatchedFolder(path: music.scan.path, kind: .local)
    let scanner = LibraryScanner(databaseURL: databaseURL)
    _ = try scanner.scan(half)
    let index = try LibraryIndex(at: databaseURL)
    let tracks = try index.trackCount()
    let filler = try fill(mount)
    do {
        let summary = try scanner.scan(whole)
        failures.append("a scan with no room stored \(summary.read) files without failing")
    } catch {
        print("database: the scan failed: \(error)", to: &standardError)
    }
    if try index.trackCount() != tracks { failures.append("the failed scan changed the tracks") }
    let playlists = try index.playlists().count
    do {
        let id = try index.createPlaylist(named: "Full")
        _ = try index.addToPlaylist(id, trackIDs: try index.trackIDs(sortedBy: .path))
        // The log may still have room from the scan's rolled-back frames, so an edit can fit.
        print("database: the playlist edit fit in the log", to: &standardError)
    } catch {
        print("database: the playlist edit failed: \(error)", to: &standardError)
        if try index.playlists().count != playlists {
            failures.append("the failed playlist edit left a playlist")
        }
    }
    let check = try Database(at: databaseURL).prepare("PRAGMA integrity_check").map {
        try $0.text(0)
    }
    if check != ["ok"] { failures.append("integrity_check: \(check)") }
    try FileManager.default.removeItem(at: filler)
    let summary = try scanner.scan(whole)
    if try !summary.issues.isEmpty || index.trackCount() <= tracks {
        failures.append("the scan with room again didn't store the files: \(summary)")
    }
    return failures
}

/// A state save with no room throws, and the file and the store keep the last saved value.
private func stateFile(on mount: URL) throws -> [String] {
    let paths = AppPaths(home: try home("state", on: mount))
    var failures: [String] = []
    let state = try StateStore(AppState(), fileURL: paths.stateFile)
    try state.set(\.sidebarWidth, to: 200)
    let saved = try Data(contentsOf: paths.stateFile)
    let filler = try fill(mount)
    do {
        try state.set(\.sidebarWidth, to: 300)
        failures.append("a save with no room didn't fail")
    } catch {
        print("state file: the save failed: \(error)", to: &standardError)
    }
    if try Data(contentsOf: paths.stateFile) != saved { failures.append("the file changed") }
    if state[\.sidebarWidth] != 200 { failures.append("the store took the unsaved value") }
    let left = try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path)
    if left != [paths.stateFile.lastPathComponent] {
        failures.append("the failed save left files: \(left)")
    }
    try FileManager.default.removeItem(at: filler)
    try state.set(\.sidebarWidth, to: 300)
    if try StateStore(AppState(), fileURL: paths.stateFile)[\.sidebarWidth] != 300 {
        failures.append("the save with room again didn't write")
    }
    return failures
}

/// A config change with no room shows as a write failure, keeps the file as it was, and is
/// written by the retry once there's room.
@MainActor
private func configFile(on mount: URL) throws -> [String] {
    let paths = AppPaths(home: try home("config", on: mount))
    var failures: [String] = []
    let config = ConfigStore(
        AppSettings(), fileURL: paths.configFile, check: { _, _, _ in nil }, creating: true)
    let saved = try Data(contentsOf: paths.configFile)
    let hogMode = config[\.hogMode]
    let filler = try fill(mount)
    try config.set(\.hogMode, to: !hogMode)
    if let failure = config.writeFailure {
        print("config file: the write failed: \(failure)", to: &standardError)
    } else {
        failures.append("a write with no room wasn't reported")
    }
    if try Data(contentsOf: paths.configFile) != saved { failures.append("the file changed") }
    try FileManager.default.removeItem(at: filler)
    // The retry is a second after the failure, on the main queue.
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    if config.writeFailure != nil { failures.append("the retry with room again failed") }
    let reread = try ConfigStore.strict(
        AppSettings(), fileURL: paths.configFile, check: { _, _, _ in nil })
    if reread[\.hogMode] == hogMode { failures.append("the retry didn't write the change") }
    return failures
}

/// A tag edit whose journal has no room stops before any music file is replaced.
private func tagJournal(on mount: URL, music: MusicFolders) throws -> [String] {
    let journalHome = try home("journal", on: mount)
    var failures: [String] = []
    let files = try audioFiles(in: music.tags)
    let originals = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    let writer = TagWriter(journal: TagUndoJournal(dataDirectory: journalHome))
    let filler = try fill(mount)
    let report = writer.write(TagEdit(values: [.title: "Full"]), to: files)
    if let first = report.failures.first, [.diskFull, .journal].contains(first.kind) {
        print("tag journal: \(first)", to: &standardError)
    } else {
        failures.append("expected a full-disk or journal failure, got \(report)")
    }
    if !report.changed.isEmpty { failures.append("files were written: \(report.changed)") }
    if report.notWritten.count + report.failures.count < files.count {
        failures.append("files weren't reported: \(report)")
    }
    let now = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    if now != originals { failures.append("a music file changed") }
    let temps = try FileManager.default.contentsOfDirectory(atPath: music.tags.path)
        .filter { $0.hasSuffix(".tagwrite") }
    if !temps.isEmpty { failures.append("temp files were left: \(temps)") }
    try FileManager.default.removeItem(at: filler)
    let written = writer.write(TagEdit(values: [.title: "Full"]), to: files)
    let undone = writer.undoLast()
    let restored = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    if !written.failures.isEmpty || !undone.failures.isEmpty || restored != originals {
        failures.append("with room again the edit and undo failed: \(written), \(undone)")
    }
    return failures
}

/// Standard error, for `print(_:to:)`.
nonisolated(unsafe) var standardError = StandardError()

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) { FileHandle.standardError.write(Data(string.utf8)) }
}
