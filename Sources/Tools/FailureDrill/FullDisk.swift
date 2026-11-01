import Fixtures
import Foundation
import Library
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

/// Fills the volume at `mount`, with a filler file to delete to give the room back.
private func fill(_ mount: URL) throws -> URL {
    let filler = mount.appendingPathComponent("filler")
    try fillVolume(with: filler)
    print("filled \(mount.path)", to: &standardError)
    return filler
}

/// The title the full-disk edits write.
private let fullDiskTitle = "Full"

/// A playlist edit and a scan with no room: each fails, is rolled back whole, and the database
/// stays sound; with room again both work.
private func database(on mount: URL, music: MusicFolders) throws -> [String] {
    let databaseURL = libraryFileURL(in: try home("database", on: mount))
    var failures: [String] = []
    let half = WatchedFolder(path: music.scan.path, kind: .local, exclude: [evenTracks])
    let whole = WatchedFolder(path: music.scan.path, kind: .local)
    let scanner = LibraryScanner(databaseURL: databaseURL)
    _ = try scanner.scan(half)
    let index = try LibraryIndex(at: databaseURL)
    let tracks = try index.trackCount()
    let playlists = try index.playlists().count
    // An empty log, so every write needs new room.
    try index.checkpoint()
    let filler = try fill(mount)
    do {
        let id = try index.createPlaylist(named: fullDiskTitle)
        _ = try index.addToPlaylist(id, trackIDs: try index.trackIDs(sortedBy: .path))
        failures.append("a playlist edit with no room didn't fail")
    } catch {
        print("database: the playlist edit failed: \(error)", to: &standardError)
    }
    if try index.playlists().count != playlists {
        failures.append("the failed playlist edit left a playlist")
    }
    do {
        let summary = try scanner.scan(whole)
        failures.append("a scan with no room stored \(summary.read) files without failing")
    } catch {
        print("database: the scan failed: \(error)", to: &standardError)
    }
    if try index.trackCount() != tracks { failures.append("the failed scan changed the tracks") }
    failures += integrityFailures(databaseURL)
    try FileManager.default.removeItem(at: filler)
    let summary = try scanner.scan(whole)
    if try !summary.issues.isEmpty || index.trackCount() <= tracks {
        failures.append("the scan with room again didn't store the files: \(summary)")
    }
    _ = try index.createPlaylist(named: fullDiskTitle)
    if try index.playlists().count != playlists + 1 {
        failures.append("the playlist edit with room again didn't store the playlist")
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
        AppSettings(), fileURL: paths.configFile, check: acceptingEveryShortcut, creating: true)
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
        AppSettings(), fileURL: paths.configFile, check: acceptingEveryShortcut)
    if reread[\.hogMode] == hogMode { failures.append("the retry didn't write the change") }
    return failures
}

/// A tag edit whose journal runs out of room after its first file is replaced: the next file's
/// record can't be written, so the batch stops there, before that file is replaced, and says
/// which files it didn't write. Undo then puts the first back.
private func tagJournal(on mount: URL, music: MusicFolders) throws -> [String] {
    let journalHome = try home("journal", on: mount)
    var failures: [String] = []
    let files = try audioFiles(in: music.tags)
    guard files.count >= 3 else { throw DrillError("the full-disk edit needs three files") }
    let originals = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    var writer = TagWriter(journal: TagUndoJournal(dataDirectory: journalHome))
    let filler = mount.appendingPathComponent("filler")
    writer.faults.beforeReplacing = { _, _ in try fillVolume(with: filler) }
    let report = writer.write(TagEdit(values: [.title: fullDiskTitle]), to: files)
    if report.failures.map(\.kind) == [.diskFull],
        report.failures[0].path.hasPrefix(journalHome.path)
    {
        print("tag journal: \(report.failures[0])", to: &standardError)
    } else {
        failures.append("expected one full-disk failure in the journal, got \(report.failures)")
    }
    if report.changed != [files[0]] { failures.append("written: \(report.changed)") }
    if report.notWritten != Array(files[2...]) {
        failures.append("reported as not written: \(report.notWritten)")
    }
    let now = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    if now[1...] != originals[1...] { failures.append("a file after the first changed") }
    let temps = files.map(tempPath(for:)).filter { FileManager.default.fileExists(atPath: $0) }
    if !temps.isEmpty { failures.append("temp files were left: \(temps)") }
    try FileManager.default.removeItem(at: filler)
    let undone = writer.undoLast()
    let restored = try files.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    if !undone.failures.isEmpty || restored != originals {
        failures.append("with room again the undo failed: \(undone)")
    }
    return failures
}

/// Standard error, for `print(_:to:)`.
nonisolated(unsafe) var standardError = StandardError()

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) { FileHandle.standardError.write(Data(string.utf8)) }
}
