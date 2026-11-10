import Recommender

/// The release a staged job's files were tagged as in the tagger, where it isn't the one the
/// job was queued for (ADR 0178), and the job's folder they were tagged in. Kept in this Mac's
/// import ledger, since music-recommender has no call yet to record a job's new release.
package struct TaggedRelease: Equatable, Sendable {
    /// The job's folder in the staging folder when its files were tagged.
    package var folder: String
    package var releaseID: Int

    /// The release `job`'s files are tagged as, when it isn't the one the service lists: nil
    /// once the job is staged in another folder, whose files are new, or the service lists
    /// this release.
    package func differs(for job: DownloadJob) -> Int? {
        job.stagedFolder == folder && job.release.releaseID != releaseID ? releaseID : nil
    }
}
