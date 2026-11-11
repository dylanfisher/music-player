import Foundation

/// A job Upgrade to FLAC Automatically queued on music-recommender, as the service numbers it.
package struct AutoUpgradeJob: Equatable, Hashable, Sendable {
    /// The service's epoch when it was queued; ids of another epoch name other jobs.
    package var epoch: String
    package var jobID: Int
    package var releaseID: Int

    package init(epoch: String, jobID: Int, releaseID: Int) {
        self.epoch = epoch
        self.jobID = jobID
        self.releaseID = releaseID
    }
}

/// A release's misses, the jobs that found no clean copy (ADR 0200).
package struct UpgradeMiss: Equatable, Sendable {
    package var misses: Int
    /// When it may be queued again, in seconds since 1970; nil once it's set aside.
    package var retryAt: Double?

    package var isSetAside: Bool { retryAt == nil }
}

/// How long a release waits after each miss before it's queued again; the miss after the last
/// sets it aside.
let upgradeRetryDays = [1, 7, 30]

/// Upgrade to FLAC Automatically's records (ADR 0200): Never Upgrade, synced as ratings are,
/// and this Mac's own jobs and misses, by release and job, never by album or path ID.
extension LibraryIndex {
    /// The releases marked Never Upgrade.
    package func neverUpgradeReleases() throws -> Set<Int> {
        Set(try statement("SELECT release_id FROM \(neverUpgradeTable)").map { try $0.int(0) })
    }

    /// Marks `releases` Never Upgrade, or clears them, logging each for the other Macs.
    package func setNeverUpgrade(_ never: Bool, releases: [Int]) throws {
        try database.transaction {
            for release in Set(releases).sorted() {
                try setNeverUpgrade(never, release: release)
                try logSync(
                    .neverUpgrade(release: release, never: never),
                    field: (.neverUpgrade, Int64(release)))
            }
        }
    }

    /// Marks the releases of the tracks `ids` Never Upgrade, or clears them when every one is
    /// marked already. Gives what they are now; nil when no track carries a release id that's
    /// a number.
    package func toggleNeverUpgrade(trackIDs ids: [Int64]) throws -> Bool? {
        let query = try statement(
            "SELECT discogs_release_id FROM tracks WHERE file_id = ? AND discogs_release_id"
                + " IS NOT NULL")
        var releases: Set<Int> = []
        for id in ids {
            for text in try query.map(id, row: { try $0.text(0) }) {
                if let release = Int(text), release > 0 { releases.insert(release) }
            }
        }
        guard !releases.isEmpty else { return nil }
        let never = !releases.isSubset(of: try neverUpgradeReleases())
        try setNeverUpgrade(never, releases: Array(releases))
        return never
    }

    /// Gives `release` its mark, writing nothing else. Call inside a transaction.
    func setNeverUpgrade(_ never: Bool, release: Int) throws {
        try statement(
            never
                ? "INSERT OR IGNORE INTO \(neverUpgradeTable) (release_id) VALUES (?)"
                : "DELETE FROM \(neverUpgradeTable) WHERE release_id = ?"
        ).run(release)
    }

    // MARK: This Mac's jobs and misses

    package func autoUpgradeJobs() throws -> [AutoUpgradeJob] {
        try statement(
            "SELECT epoch, job_id, release_id FROM \(autoUpgradeJobsTable) ORDER BY epoch, job_id"
        ).map {
            AutoUpgradeJob(epoch: try $0.text(0), jobID: try $0.int(1), releaseID: try $0.int(2))
        }
    }

    package func recordAutoUpgradeJob(_ job: AutoUpgradeJob) throws {
        try statement(
            "INSERT OR REPLACE INTO \(autoUpgradeJobsTable) (epoch, job_id, release_id)"
                + " VALUES (?, ?, ?)"
        ).run(job.epoch, job.jobID, job.releaseID)
    }

    package func forgetAutoUpgradeJob(_ job: AutoUpgradeJob) throws {
        try statement("DELETE FROM \(autoUpgradeJobsTable) WHERE epoch = ? AND job_id = ?").run(
            job.epoch, job.jobID)
    }

    /// Each release's misses, by release.
    package func upgradeMisses() throws -> [Int: UpgradeMiss] {
        Dictionary(
            uniqueKeysWithValues: try statement(
                "SELECT release_id, misses, retry_seconds FROM \(upgradeMissesTable)"
            ).map {
                (
                    try $0.int(0),
                    UpgradeMiss(misses: try $0.int(1), retryAt: $0.optionalDouble(2))
                )
            })
    }

    /// Counts a miss of `job`'s release at `seconds` and forgets the job, in one transaction:
    /// the release waits 1, 7 or 30 days after its first three, and the fourth sets it aside.
    /// Gives the release's misses now.
    @discardableResult
    package func recordUpgradeMiss(_ job: AutoUpgradeJob, at seconds: Double) throws
        -> UpgradeMiss
    {
        try database.transaction {
            let misses =
                (try statement("SELECT misses FROM \(upgradeMissesTable) WHERE release_id = ?")
                    .map(job.releaseID) { try $0.int(0) }.first ?? 0) + 1
            let miss = UpgradeMiss(
                misses: misses,
                retryAt: misses <= upgradeRetryDays.count
                    ? seconds + Double(upgradeRetryDays[misses - 1]) * 86_400 : nil)
            try statement(
                "INSERT OR REPLACE INTO \(upgradeMissesTable) (release_id, misses, retry_seconds)"
                    + " VALUES (?, ?, ?)"
            ).run(job.releaseID, miss.misses, miss.retryAt)
            try forgetAutoUpgradeJob(job)
            return miss
        }
    }

    /// Queue Again: forgets `releases`' misses, so they're candidates again.
    package func clearUpgradeMisses(releases: [Int]) throws {
        try database.transaction {
            let delete = try statement("DELETE FROM \(upgradeMissesTable) WHERE release_id = ?")
            for release in releases { try delete.run(release) }
        }
    }
}
