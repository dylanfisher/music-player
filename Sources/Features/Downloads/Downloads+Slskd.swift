import Foundation
import Log
import Recommender

private let logger = moduleLogger()

/// slskd's web page, for Open slskd.
extension Downloads {
    /// Asks the service where slskd's page is, for Open slskd, each time the window opens, so
    /// a change to the service's config shows on the next.
    func askForSlskd() {
        guard let session else { return }
        let page = session.setup.service.slskdPage
        Task {
            do throws(RecommenderError) {
                let found = try await page()
                guard self.session === session else { return }
                session.slskdPage = found
            } catch {
                logger.info("slskd's page wasn't found: \(error)")
            }
            refresh()
        }
    }

    /// Opens slskd's web page, where the service says it is.
    func openSlskd() {
        guard let page = session?.slskdPage else { return }
        openPage(page)
    }
}
