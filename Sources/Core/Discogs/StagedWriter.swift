import Darwin
import Foundation
import Settings
import TagWriter

/// Writes a clean staged album's tags once, unasked (ADR 0146), through `TagWriter` with a
/// journal of its own, so a crash mid-write is put back at the next write on this Mac and
/// Edit > Undo never sees it. Nothing here tells the library watcher, so no staged file is
/// read into the index. Calls block on file I/O; make them off the main thread.
package struct StagedWriter: Sendable {
    /// Where the staged journal is kept under the app's data directory, apart from the main
    /// one's `tag-undo`.
    static let folderName = "staged-tags"

    /// The staging folder as found, which every path written must be inside.
    let stagingRoot: String
    let writer: TagWriter

    package init(stagingRoot: String, dataDirectory: URL) {
        self.stagingRoot = stagingRoot
        writer = TagWriter(
            journal: TagUndoJournal(
                dataDirectory: dataDirectory.appendingPathComponent(
                    Self.folderName, isDirectory: true)))
    }

    /// Writes `run`'s edits when it's clean, then reads the files back and works out the
    /// change set again with `mapping`, which must find nothing. Returns the verdict to
    /// report: clean when that held, else why not. A path outside the staging folder, its
    /// symbolic links followed, refuses the whole run before anything is written.
    package func write(_ run: AutoTagRun, mapping: DiscogsMapping) -> AutoTagRun.Verdict {
        guard run.verdict == .clean, let match = run.match else { return run.verdict }
        let report: TagWriteReport
        do throws(StagedPathRefused) {
            report = try write(run.edits)
        } catch {
            return .error([error.description])
        }
        guard report.failures.isEmpty, report.notWritten.isEmpty else {
            return .error(
                report.failures.map(\.description)
                    + report.notWritten.map { "\($0) wasn't written" })
        }
        let read = readAlbumFiles(run.staged.files.map { (id: $0.id, path: $0.path) })
        guard read.problems.isEmpty else { return .error(read.problems) }
        let left = changeSet(for: read.files, match: match, mapping: mapping.overwriting())
            .files.flatMap(\.changes)
        return Self.verdict(readingBack: left.count)
    }

    /// The verdict of files read back after a staged write with `left` tags the mapping would
    /// still change: clean only when there are none.
    package static func verdict(readingBack left: Int) -> AutoTagRun.Verdict {
        left == 0 ? .clean : .discrepancy(["the files read back with \(left) tags still to change"])
    }

    /// Finishes any write a crash left unconfirmed in the staged journal: a file the crash
    /// tore is put back from it. Run it before the first staged write after a launch.
    package func recoverInterrupted() -> TagWriteReport { writer.recoverInterrupted() }

    /// Writes `edits` with the staged journal and nothing else: the write the staged tagger's
    /// Apply uses too, which no watcher hears of. Paths outside the staging folder are
    /// refused before any is written.
    package func write(_ edits: [(path: String, edit: TagEdit)]) throws(StagedPathRefused)
        -> TagWriteReport
    {
        if let refused = refusedPath(edits.map(\.path)) {
            throw StagedPathRefused(path: refused, stagingRoot: stagingRoot)
        }
        return writer.write(edits)
    }

    /// The first of `paths` that isn't inside the staging folder once every symbolic link in
    /// it and in the folder is followed, or that doesn't exist; nil when none.
    func refusedPath(_ paths: [String]) -> String? {
        guard let root = resolved(stagingRoot) else { return paths.first ?? stagingRoot }
        return paths.first { path in
            guard let real = resolved(path) else { return true }
            return !real.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }
}

/// A path a staged write was asked to write outside the staging folder (ADR 0146).
package struct StagedPathRefused: Error, Equatable, CustomStringConvertible {
    var path: String
    var stagingRoot: String

    package var description: String { "\(path) isn't inside the staging folder \(stagingRoot)" }
}

/// `path` with every symbolic link followed and `.` and `..` gone; nil when it doesn't exist.
private func resolved(_ path: String) -> String? {
    guard let real = realpath(path, nil) else { return nil }
    defer { free(real) }
    return String(cString: real)
}
