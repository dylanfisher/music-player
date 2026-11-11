import Recommender

/// What the Downloads window's toolbar and context menu do to one job. Whether each applies is
/// a pure function of the job, this Mac and the service, table-tested, so the window only asks.
enum DownloadAction: CaseIterable, Sendable {
    case approve, reject, retry, cancel, openInTagger, resumeHere, revealInFinder

    var title: String {
        switch self {
        case .approve: "Approve…"
        case .reject: "Reject…"
        case .retry: "Retry"
        case .cancel: "Cancel Download"
        case .openInTagger: "Open in Tagger"
        case .resumeHere: "Resume Here"
        case .revealInFinder: "Reveal in Finder"
        }
    }

    var help: String {
        switch self {
        case .approve: "Review where the files go, then move them into the library."
        case .reject: "Have the service delete the staged folder."
        case .retry: "Start the job again from where it failed."
        case .cancel: "Stop the search or download and delete what it got."
        case .openInTagger: "Resolve the discrepancy in the Discogs Tagger."
        case .resumeHere: "Finish an import another Mac, or an earlier run, left."
        case .revealInFinder: "Show the album's staged folder in the Finder."
        }
    }

    /// Whether the action applies to `job` on the Mac named `machine`. Nothing applies while
    /// the service doesn't answer; a job another Mac is reviewing takes only Resume Here, which
    /// takes the claim over. Approve needs the job staged and tagged clean; Open in Tagger a
    /// discrepancy or an error, on a Mac with a catalog (`canTag`). Reveal in Finder, which only
    /// looks, needs a staged folder, from `staged` until the import, and not the service.
    static func applies(
        _ action: DownloadAction, to job: DownloadJob, machine: String, answering: Bool,
        canTag: Bool
    ) -> Bool {
        if action == .revealInFinder {
            return job.stagedPath != nil
                && [.staged, .approved, .importing, .failed].contains(job.state)
        }
        guard answering else { return false }
        let elsewhere = DownloadRow.claimedElsewhere(job.review, machine: machine) != nil
        switch action {
        case .approve:
            return !elsewhere && job.state == .staged && job.tagging.status == .clean
        case .reject:
            return !elsewhere && job.state == .staged
        case .retry:
            return job.state == .notFound || job.state == .failed
        case .cancel:
            switch job.state {
            case .queued, .searching, .notFound, .candidateFound, .downloading, .downloaded:
                return true
            case .staged: return !elsewhere
            case .failed:
                return [.search, .download, .stage, .tag].contains(job.failedStage)
            case .approved, .importing, .imported, .rejected, .cancelled: return false
            }
        case .openInTagger:
            return canTag && !elsewhere && job.state == .staged
                && (job.tagging.status == .discrepancy || job.tagging.status == .error)
        case .resumeHere:
            return job.state == .approved || job.state == .importing
        // Answered before the service's guard.
        case .revealInFinder: return false
        }
    }

    /// Whether Retry asks for a format first: a retry that searches again takes a new policy,
    /// and the service refuses one on any other.
    static func retrySearches(_ job: DownloadJob) -> Bool {
        job.state == .notFound
            || (job.state == .failed
                && (job.failedStage == .search || job.failedStage == .download))
    }
}

/// The ways to queue a download, in the toolbar's Add menu.
enum DownloadAddition: CaseIterable, Sendable {
    case upgrades, fromSelection, pasteRelease, notFound

    var title: String {
        switch self {
        case .upgrades: "Upgrades…"
        case .fromSelection: "From Library Selection…"
        case .pasteRelease: "Paste a Discogs Release…"
        case .notFound: "Not Found Upgrades…"
        }
    }
}

extension FormatPolicy {
    /// The policies a job may ask for: an upgrade only lossless ones, so it can't replace a
    /// lossy album with another.
    static func offered(upgrade: Bool) -> [FormatPolicy] {
        upgrade ? JobOrder.LosslessPolicy.allCases.map(\.formatPolicy) : allCases
    }
}
