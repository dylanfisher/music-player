import Recommender

/// Where an album downloaded through music-recommender came from (ADR 0207), kept by Discogs
/// release id. An upgrade isn't one: the album came from wherever it came from first.
package enum DownloadSource: String, CaseIterable, Sendable {
    case recommendation, manual

    /// As Download Source shows it, and a smart rule compares it, whatever its case.
    package var title: String {
        switch self {
        case .recommendation: "Recommendation"
        case .manual: "Manual"
        }
    }

    /// What a job made from `source` records; nil for an upgrade, which records none of its own.
    init?(_ source: DownloadJob.Source) {
        switch source {
        case .recommendation: self = .recommendation
        case .manual: self = .manual
        case .upgrade: return nil
        }
    }
}

/// A release's first import: where it came from and when, in seconds since 1970.
struct DownloadOrigin: Equatable, Sendable {
    var source: DownloadSource
    var importedSeconds: Double
}

/// Download Source's records (ADR 0207): one row a release, the first import's, synced so
/// every Mac keeps the earliest.
extension LibraryIndex {
    /// Each release's first import, by release id.
    func downloadOrigins() throws -> [Int: DownloadOrigin] {
        var found: [Int: DownloadOrigin] = [:]
        try statement(
            "SELECT release_id, source, imported_seconds FROM \(downloadSourcesTable)"
        ).query { row in
            let text = try row.text(1)
            guard let source = DownloadSource(rawValue: text) else {
                throw LibraryError.notADownloadSource(text)
            }
            found[try row.int(0)] = DownloadOrigin(
                source: source, importedSeconds: try row.double(2))
        }
        return found
    }

    /// Records where `job` came from, now that its files are in the library, and logs it for
    /// the other Macs. Keyed by the release its files carry: the one the tagger tagged them
    /// as, where it did (ADR 0178). The first import of a release wins. An upgrade gives a new
    /// release id the source of the release it replaces; it records nothing of its own. The
    /// replaced releases come from the job's ledger, not the sheet's `upgrade`, which a resume
    /// after the old files are gone can't rebuild. Call inside a transaction.
    func recordDownloadSource(of job: ApprovedImport) throws {
        // Only this job's steps, so another job's bad row can't fail this import.
        let steps = try importSteps(job: job.jobID)
        var release = job.releaseID
        if let retagged = steps.first(where: { $0.kind == .retagged }) {
            let text = retagged.destination ?? ""
            guard let id = Int(text) else { throw LibraryError.notAReleaseID(text) }
            release = id
        }
        // The old files held to another release than the job's carry it; the others, the job's.
        var replaced = Set(
            steps.filter { $0.kind == .held }.compactMap { $0.destination.flatMap { Int($0) } })
        if steps.contains(where: { $0.kind == .trashed }) { replaced.insert(job.releaseID) }
        replaced.remove(release)
        let origins = try downloadOrigins()
        let origin: DownloadOrigin
        if let carried = replaced.compactMap({ origins[$0] }).min(by: earlier) {
            origin = carried
        } else if let source = DownloadSource(job.source) {
            origin = DownloadOrigin(source: source, importedSeconds: Double(wallClockMs()) / 1000)
        } else {
            return
        }
        try statement("INSERT OR IGNORE INTO \(downloadSourcesTable) \(downloadSourceValues)").run(
            release, origin.source.rawValue, origin.importedSeconds)
        guard database.changes == 1 else { return }
        try logSync(
            .downloadSource(
                release: release, source: origin.source, at: origin.importedSeconds))
    }

    /// Takes another Mac's record of `release` when it's the earlier import, or this Mac has
    /// none. Gives whether the row changed.
    func mergeDownloadSource(release: Int, _ origin: DownloadOrigin) throws -> Bool {
        // A tie on the time goes to the source that sorts first, so every Mac keeps the same.
        try statement(
            "INSERT INTO \(downloadSourcesTable) \(downloadSourceValues)"
                + " ON CONFLICT (release_id) DO UPDATE SET"
                + " source = excluded.source, imported_seconds = excluded.imported_seconds"
                + " WHERE excluded.imported_seconds < imported_seconds"
                + " OR (excluded.imported_seconds = imported_seconds AND excluded.source < source)"
        ).run(release, origin.source.rawValue, origin.importedSeconds)
        return database.changes == 1
    }
}

/// A row's columns and their values, as both writes give them.
private let downloadSourceValues = "(release_id, source, imported_seconds) VALUES (?, ?, ?)"

/// Whether `one` was imported before `other`, a tie going to the source that sorts first, as
/// the merge decides it.
private func earlier(_ one: DownloadOrigin, _ other: DownloadOrigin) -> Bool {
    (one.importedSeconds, one.source.rawValue) < (other.importedSeconds, other.source.rawValue)
}
