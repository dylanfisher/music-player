import Foundation
import Library
import SQLite
import Settings
import TagWriter

/// Reopens what a killed run left, as the app's next launch would, and returns every integrity
/// failure: a database that fails `PRAGMA integrity_check` or that the library can't open as it
/// is, a config or state file that doesn't decode or whose cut-short save is still beside it
/// once its store has opened, and a journaled edit that doesn't undo. The caller then compares
/// the music files with their hashes from before the run.
@MainActor
func verify(home: URL) throws -> [String] {
    let paths = AppPaths(home: home)
    var failures: [String] = []
    let databaseURL = libraryFileURL(in: paths.dataDirectory)
    if FileManager.default.fileExists(atPath: databaseURL.path) {
        failures += integrityFailures(databaseURL)
        do {
            let index = try LibraryIndex(at: databaseURL)
            if let discard = try index.discards().first {
                failures.append("the library discarded data: \(discard.text)")
            }
        } catch {
            failures.append("the library doesn't open: \(error)")
        }
    }
    if FileManager.default.fileExists(atPath: paths.stateFile.path) {
        let state = try StateStore(AppState(), fileURL: paths.stateFile)
        if let reason = state.discardReason { failures.append("the state file: \(reason)") }
    }
    if FileManager.default.fileExists(atPath: paths.configFile.path) {
        do {
            _ = try ConfigStore.strict(
                AppSettings(), fileURL: paths.configFile, check: acceptingEveryShortcut)
        } catch {
            failures.append("the config file: \(error)")
        }
    }
    for file in [paths.stateFile, paths.configFile] {
        failures += leftoverAtomicWrites(beside: file).map { "a save left \($0)" }
    }
    failures += undoEveryEdit(paths.dataDirectory)
    return failures
}

/// What's wrong with the database at `databaseURL`, by `PRAGMA integrity_check`, or that it
/// doesn't open.
func integrityFailures(_ databaseURL: URL) -> [String] {
    do {
        let result = try Database(at: databaseURL).prepare("PRAGMA integrity_check").map {
            try $0.text(0)
        }
        return result == ["ok"] ? [] : ["integrity_check: \(result)"]
    } catch {
        return ["the database doesn't open: \(error)"]
    }
}

/// Undoes every edit in the journal, newest first. A record whose file was never renamed over
/// (the kill came first) reads as changed since and is dropped: its file is the original. A
/// record the kill cut short is discarded with a report, and its file wasn't renamed either.
private func undoEveryEdit(_ dataDirectory: URL) -> [String] {
    let writer = TagWriter(journal: TagUndoJournal(dataDirectory: dataDirectory))
    var failures: [String] = []
    while true {
        let report = writer.undoLast()
        if report.nothingToUndo { return failures }
        let unexpected = report.failures.filter {
            ![.changedSinceEdit, .journal].contains($0.kind)
        }
        failures += unexpected.map { "undo: \($0)" }
        // A failure other than those stays in the journal and would be tried forever.
        if !unexpected.isEmpty { return failures }
    }
}
