import Library
import Recommender

extension Downloads {
    /// Show in All Music: the album the job imported, under the release its files were tagged
    /// as, or the album an upgrade replaces, found by its release in the index. One not there
    /// says so in the status line, until the next lookup, a change of selection or of session.
    func showInLibrary(_ job: DownloadJob, _ session: Session) {
        forgetNotShown()
        let release =
            job.state == .imported
            ? session.model.taggedAs(job.id) ?? job.release.releaseID : job.release.releaseID
        let database = session.setup.databaseURL
        let find = albumOfRelease
        Task {
            let album: Int64?
            do {
                album = try await find(database, release)
            } catch {
                return alert("The album wasn't shown", ["\(error)"])
            }
            guard self.session === session else { return }
            guard let album else {
                notShown = LibraryIndex.releaseNotInLibrary(release)
                return refresh()
            }
            showInAllMusic(album)
        }
    }

    /// Stops saying the last Show in All Music found nothing.
    func forgetNotShown() {
        guard notShown != nil else { return }
        notShown = nil
        refresh()
    }
}
