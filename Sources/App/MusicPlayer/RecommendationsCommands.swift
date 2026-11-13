import Commands
import Foundation
import Library
import LibraryBrowser
import Recommendations
import Recommender
import Settings

/// music-recommender's lists (ADR 0205), and the profile, sent by Send Library Profile to
/// Service and unasked at launch and after a scan that changed the library (ADR 0206), while
/// the service's address and token are set.
extension AppDelegate {
    func registerRecommendationsCommands(_ dispatcher: CommandDispatcher) {
        let serviceIsSet = { [weak self] in
            guard let self, window != nil, let settings else { return false }
            return downloadsAreSet(settings)
        }
        dispatcher.handle(.showRecommendations, enabled: hasWindow) { [weak self] in
            self?.recommendations.show()
        }
        let canSeed = { [weak self] in self?.hasSelectedTracks() == true && serviceIsSet() }
        for (command, kind) in [
            (CommandID.recommendationsForAlbum, SeedKind.album),
            (.recommendationsForArtist, .artist),
        ] {
            dispatcher.handle(command, enabled: canSeed) { [weak self] in
                self?.showRecommendations(kind)
            }
        }
        dispatcher.handle(.sendLibraryProfile, enabled: serviceIsSet) { [weak self] in
            self?.recommendations.sendProfile()
        }
    }

    /// `events`, the Library Analysis standing shown again and the profile sent, if it
    /// changed, after each scan that changed the library.
    func standingAndProfileFollowing(
        _ events: @escaping @Sendable (WatcherEvent) -> Void
    ) -> @Sendable (WatcherEvent) -> Void {
        profileSentFollowing(analysisStandingFollowing(events))
    }

    private func profileSentFollowing(
        _ events: @escaping @Sendable (WatcherEvent) -> Void
    ) -> @Sendable (WatcherEvent) -> Void {
        { [weak self] event in
            events(event)
            let changed: Bool =
                switch event {
                case .scanned(_, let summary): summary.read > 0 || summary.removed > 0
                case .removed: true
                default: false
                }
            guard changed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.recommendations.sendProfileIfChanged() }
            }
        }
    }

    private func showRecommendations(_ kind: SeedKind) {
        guard let browser else { return }
        do {
            recommendations.show(kind, forTracks: try browser.selectedTrackIDs())
        } catch {
            browser.reportCommand("couldn't read the selection for its recommendations", error)
        }
    }

    func makeRecommendations() -> Recommendations {
        let recommendations = Recommendations(
            databaseURL: libraryFileURL(in: paths.dataDirectory))
        recommendations.service = { [weak self] in self?.recommendationsService() }
        recommendations.say = { [weak self] in self?.browser?.show(failure: $0) }
        recommendations.report = { [weak self] in self?.browser?.report($0) }
        recommendations.download = { [weak self] in self?.downloads.queue(recommended: $0) }
        recommendations.catalog = { [weak self] in
            guard let self, let settings else { return nil }
            return paths.discogsCatalogFile(settings[\.discogsCatalogPath])
        }
        if let state { recommendations.columnWidths = state[\.recommendationsColumns] }
        recommendations.columnWidthsChanged = { [weak self] in
            self?.saver?.set(\.recommendationsColumns, $0)
        }
        return recommendations
    }

    /// The calls to the service at its address, port and token as set now, or nil while the
    /// address or token isn't set.
    private func recommendationsService() -> RecommendationsService? {
        guard let settings, let address = settings[\.recommenderAddress]?.address,
            let token = settings[\.recommenderToken]
        else { return nil }
        let port = UInt16(settings[\.recommenderPort])
        return RecommendationsService { () throws(RecommenderError) in
            try RecommenderClient(address: address, port: port, token: token)
        }
    }
}
