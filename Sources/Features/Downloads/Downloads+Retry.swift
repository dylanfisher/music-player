import AppKit
import Recommender

extension Downloads {
    /// Retry: a job that failed or wasn't found starts again, asking for a format when it
    /// searches again; a staged one requeues.
    func retry(_ job: DownloadJob, _ row: DownloadRow, _ session: Session) {
        let send = { (policy: FormatPolicy?) in
            _ = Task {
                if let problem = await session.model.retry(job.id, policy: policy) {
                    self.alert("The job wasn't started again", [problem])
                }
            }
        }
        if job.state == .staged { return requeue(job, row, session) }
        guard DownloadAction.retrySearches(job) else { return send(nil) }
        guard let window = controller?.window else { return }
        let policies = FormatPolicy.offered(upgrade: job.source == .upgrade)
        let popUp = formatPopUp(policies)
        popUp.selectItem(at: policies.firstIndex(of: job.formatPolicy) ?? 0)
        let question = NSAlert()
        question.messageText = "Search again for \(row.album)?"
        question.informativeText = "Choose the format to ask for."
        question.accessoryView = popUp
        question.addButton(withTitle: DownloadAction.retry.title)
        question.addButton(withTitle: "Cancel")
        question.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            send(policies[popUp.indexOfSelectedItem])
        }
    }

    /// Retry on a staged copy that isn't clean, once the owner confirms: the service deletes it
    /// and downloads the album again from a user the job hasn't tried (ADR 0211).
    private func requeue(_ job: DownloadJob, _ row: DownloadRow, _ session: Session) {
        guard let coordinator = session.coordinator else { return }
        confirm(
            "Download \(row.album) again from another user?",
            "music-recommender deletes the staged copy and searches again, leaving out the users"
                + " this download has tried.", DownloadAction.retry.title
        ) {
            Task {
                if let problem = await coordinator.requeue(asked: job) {
                    self.alert("The download wasn't started again", [problem])
                }
                await session.model.poll()
            }
        }
    }
}
