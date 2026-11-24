import Discogs
import Recommender

extension Downloads {
    /// Use Release That Fits (ADR 0224): names the release queued and the one this Mac's tag
    /// run found the files fit, and once the owner confirms, has the coordinator write the
    /// files' tags as the one they fit.
    func useReleaseThatFits(_ job: DownloadJob, _ row: DownloadRow, _ session: Session) {
        guard let coordinator = session.coordinator, let fit = session.model.fit(job.id) else {
            return
        }
        let heading = "\(row.album) wasn't tagged as \(DownloadRow.releaseName(fit))"
        let catalog = session.setup.catalog
        let queued = job.release.releaseID
        Task {
            let summaries: [ReleaseSummary]
            do {
                summaries = try await releaseSummaries([queued, fit], catalogAt: catalog)
            } catch {
                return alert(heading, [Self.catalogUnread(error)])
            }
            guard let fits = summaries.first(where: { $0.id == fit }) else {
                return alert(
                    heading, [ReleaseSnapshot.Problem.notInCatalog(releaseID: fit).description])
            }
            let was =
                summaries.first { $0.id == queued }.map(Self.named)
                ?? DownloadRow.releaseName(queued)
            confirm(
                "Tag \(row.album) as \(DownloadRow.releaseName(fit))?",
                "It was queued as \(was). The files fit \(Self.named(fits)). Their tags are"
                    + " written as that release in the staging folder, and only this Mac knows it"
                    + " until the service can record it.",
                DownloadAction.tagAsReleaseButton
            ) {
                Task {
                    if let problem = await coordinator.tagAsFit(job) {
                        self.alert(heading, [problem])
                    }
                    await session.model.poll()
                }
            }
        }
    }

    /// "Artist – Title (CD, Label CAT 1, 2022), Discogs release 123".
    static func named(_ release: ReleaseSummary) -> String {
        "\(release.artist) – \(release.title) (\(release.edition)),"
            + " \(DownloadRow.releaseName(release.id))"
    }
}
