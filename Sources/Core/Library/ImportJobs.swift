/// An import step this Mac took for one of music-recommender's jobs (ADR 0139): a hint for
/// resuming, which the files themselves confirm.
struct ImportStep: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// A staged file's rename into the library folder, recorded for every file of the album
        /// before the first is renamed.
        case moved
        /// An upgrade's old file given to `moveToTrash`.
        case trashed
        /// An upgrade's old file's stats carried to its new one.
        case carried
        /// A staged file's size after the player's own tag write, which can grow the file when
        /// its padding runs out. Every check after the write holds the file to it, not to the
        /// size the service staged.
        case tagged
    }

    /// The service's job id, which every Mac shares.
    var jobID: Int
    var releaseID: Int
    var kind: Kind
    /// For `moved` and `tagged`, the file's path relative to the staging folder; otherwise the old file's,
    /// relative to the library's share.
    var path: String
    /// For `moved` and `carried`, the new file's path relative to the library's share.
    var destination: String? = nil
    /// For `moved`, the size the file must have where it went; for `tagged`, the size it has
    /// since the tag write.
    var sizeBytes: Int? = nil
}

/// A report to music-recommender waiting in the outbox.
package struct QueuedImportReport: Equatable, Sendable {
    /// Its place in the outbox; reports go in this order.
    package var seq: Int64
    package var jobID: Int
    package var releaseID: Int
    /// The request's body as it's sent.
    package var body: String
}

extension LibraryIndex {
    /// Adds a report for the job `job` of the release `release`, after every other, and
    /// returns its place.
    package func queueImportReport(job: Int, release: Int, body: String) throws -> Int64 {
        try statement(
            "INSERT INTO \(importOutboxTable) (job_id, release_id, body) VALUES (?, ?, ?)"
        ).run(job, release, body)
        return database.lastInsertRowID
    }

    /// The reports not yet delivered, oldest first.
    package func importReports() throws -> [QueuedImportReport] {
        try statement(
            "SELECT seq, job_id, release_id, body FROM \(importOutboxTable) ORDER BY seq"
        ).map { row in
            QueuedImportReport(
                seq: try row.int64(0), jobID: try row.int(1), releaseID: try row.int(2),
                body: try row.text(3))
        }
    }

    /// Drops the report at `seq`, which the service has answered.
    package func removeImportReport(_ seq: Int64) throws {
        try statement("DELETE FROM \(importOutboxTable) WHERE seq = ?").run(seq)
    }

    /// Records `step`, replacing the same job's step of the same kind on the same file, so a
    /// resumed import records each once. Paths must be relative, with no empty, `.` or `..`
    /// part, so they can't name a file outside their folder.
    func recordImportStep(_ step: ImportStep) throws {
        for path in [step.path] + (step.destination.map { [$0] } ?? []) {
            guard isRelativeInside(path) else { throw LibraryError.notRelative(path) }
        }
        try statement(
            """
            INSERT OR REPLACE INTO \(importStepsTable)
                (job_id, release_id, kind, path, destination, size_bytes)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        ).run(
            step.jobID, step.releaseID, step.kind.rawValue, step.path, step.destination,
            step.sizeBytes)
    }

    /// The steps recorded for the job `job`, by kind and path.
    func importSteps(job: Int) throws -> [ImportStep] {
        try statement(
            """
            SELECT release_id, kind, path, destination, size_bytes FROM \(importStepsTable)
            WHERE job_id = ? ORDER BY kind, path
            """
        ).map(job) { row in
            let kind = try row.text(1)
            guard let known = ImportStep.Kind(rawValue: kind) else {
                throw LibraryError.unknownKind(kind)
            }
            return ImportStep(
                jobID: job, releaseID: try row.int(0), kind: known, path: try row.text(2),
                destination: row.optionalText(3), sizeBytes: row.optionalInt(4))
        }
    }

    /// Records what the staged files of `folder` measure, by name, after the player wrote their
    /// tags, replacing any earlier record of the same files.
    package func recordStagedSizes(job: Int, release: Int, folder: String, sizes: [String: Int])
        throws
    {
        try database.transaction {
            for (name, size) in sizes {
                try recordImportStep(
                    ImportStep(
                        jobID: job, releaseID: release, kind: .tagged, path: folder + "/" + name,
                        sizeBytes: size))
            }
        }
    }

    /// The sizes recorded for the staged files of `folder` by `recordStagedSizes`, by name.
    package func stagedSizes(job: Int, folder: String) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        let prefix = folder + "/"
        for step in try importSteps(job: job) where step.kind == .tagged {
            if step.path.hasPrefix(prefix), let size = step.sizeBytes {
                sizes[String(step.path.dropFirst(prefix.count))] = size
            }
        }
        return sizes
    }

    /// Forgets the job `job`'s steps, once it's imported.
    package func forgetImportJob(_ job: Int) throws {
        try statement("DELETE FROM \(importStepsTable) WHERE job_id = ?").run(job)
    }
}

/// Whether `path` is relative and stays inside its folder: not empty, no leading slash, and no
/// empty, `.` or `..` part.
private func isRelativeInside(_ path: String) -> Bool {
    !path.isEmpty
        && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
}
