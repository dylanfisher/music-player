/// An import step this Mac took for one of music-recommender's jobs (ADR 0139): a hint for
/// resuming, which the files themselves confirm.
struct ImportStep: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// A staged file renamed into the library folder.
        case moved
        /// An upgrade's old file given to `moveToTrash`.
        case trashed
        /// An upgrade's old file's stats carried to its new one.
        case carried
    }

    /// The service's job id, which every Mac shares.
    var jobID: Int
    var releaseID: Int
    var kind: Kind
    /// For `moved`, the file's path relative to the staging folder; otherwise the old file's,
    /// relative to the library's share.
    var path: String
    /// For `moved` and `carried`, the new file's path relative to the library's share.
    var destination: String? = nil
    /// For `moved`, the size the file must have where it went.
    var sizeBytes: Int? = nil
}

/// A report to music-recommender waiting in the outbox.
struct QueuedImportReport: Equatable, Sendable {
    /// Its place in the outbox; reports go in this order.
    var seq: Int64
    var jobID: Int
    var releaseID: Int
    /// The request's body as it's sent.
    var body: String
}

extension LibraryIndex {
    /// Adds a report for the job `job` of the release `release`, after every other, and
    /// returns its place.
    func queueImportReport(job: Int, release: Int, body: String) throws -> Int64 {
        try statement(
            "INSERT INTO \(importOutboxTable) (job_id, release_id, body) VALUES (?, ?, ?)"
        ).run(job, release, body)
        return database.lastInsertRowID
    }

    /// The reports not yet delivered, oldest first.
    func importReports() throws -> [QueuedImportReport] {
        try statement(
            "SELECT seq, job_id, release_id, body FROM \(importOutboxTable) ORDER BY seq"
        ).map { row in
            QueuedImportReport(
                seq: try row.int64(0), jobID: try row.int(1), releaseID: try row.int(2),
                body: try row.text(3))
        }
    }

    /// Drops the report at `seq`, which the service has answered.
    func removeImportReport(_ seq: Int64) throws {
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

    /// Forgets the job `job`'s steps, once it's imported.
    func forgetImportJob(_ job: Int) throws {
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
