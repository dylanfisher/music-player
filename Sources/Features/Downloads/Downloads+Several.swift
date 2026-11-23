import Recommender

extension Downloads {
    /// Retry, Reject, Cancel or Reveal in Finder on several jobs (ADR 0218): one question
    /// naming the count, then each job in turn, and what went wrong said together.
    func actOnEach(
        _ action: DownloadAction, _ jobs: [(row: DownloadRow, job: DownloadJob)],
        _ session: Session
    ) {
        let count = jobs.count
        switch action {
        case .reject:
            confirm(
                "Reject \(count) downloads?",
                "music-recommender deletes their staged folders. Nothing in the library changes.",
                DownloadAction.rejectButton
            ) {
                self.each(jobs, session, failed: "rejections weren't sent") { job in
                    guard let coordinator = session.coordinator else {
                        return Self.notReviewing
                    }
                    return await coordinator.reject(job)
                }
            }
        case .cancel:
            confirm(
                "Cancel \(count) downloads?",
                "music-recommender stops them and deletes what they got.",
                DownloadAction.cancel.title
            ) {
                self.each(jobs, session, failed: "downloads weren't cancelled") {
                    await session.model.cancel($0.id)
                }
            }
        case .retry:
            confirm(
                "Retry \(count) downloads?",
                "Each starts again in the format it asked for. A staged copy that isn't clean is"
                    + " deleted and searched for again from a user the download hasn't tried.",
                DownloadAction.retry.title
            ) {
                self.each(jobs, session, failed: "downloads weren't started again") { job in
                    guard job.state == .staged else {
                        return await session.model.retry(job.id, policy: nil)
                    }
                    guard let coordinator = session.coordinator else {
                        return Self.notReviewing
                    }
                    return await coordinator.requeue(asked: job)
                }
            }
        case .revealInFinder: reveal(jobs.map(\.job), session)
        case .approve, .resumeHere, .openInTagger:
            preconditionFailure("\(action) acts on one job")
        }
    }

    /// Why a job that needs this Mac's review couldn't be sent: it hasn't started reviewing.
    static let notReviewing = "this Mac isn't reviewing downloads yet"

    /// Runs `call` on each job in turn, then says which it failed for, and asks for the jobs
    /// again.
    private func each(
        _ jobs: [(row: DownloadRow, job: DownloadJob)], _ session: Session, failed: String,
        _ call: @escaping (DownloadJob) async -> String?
    ) {
        Task {
            var problems: [String] = []
            for (row, job) in jobs {
                if let problem = await call(job) { problems.append("\(row.album): \(problem)") }
            }
            if !problems.isEmpty { alert("\(problems.count) of \(jobs.count) \(failed)", problems) }
            await session.model.poll()
        }
    }
}
