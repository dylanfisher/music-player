import Commands
import Foundation
import Library
import LibraryBrowser
import Recommendations
import Recommender
import Settings

/// music-recommender's lists (phase 86, ADR 0205): Send Library Profile to Service sends the
/// profile only when asked, while the service's address and token are set.
extension AppDelegate {
    func registerRecommendationsCommands(_ dispatcher: CommandDispatcher) {
        let serviceIsSet = { [weak self] in
            guard let self, window != nil, let settings else { return false }
            return downloadsAreSet(settings)
        }
        dispatcher.handle(.sendLibraryProfile, enabled: serviceIsSet) { [weak self] in
            self?.recommendations.sendProfile()
        }
    }

    func makeRecommendations() -> Recommendations {
        let recommendations = Recommendations(
            databaseURL: libraryFileURL(in: paths.dataDirectory))
        recommendations.service = { [weak self] in self?.recommendationsService() }
        recommendations.say = { [weak self] in self?.browser?.show(failure: $0) }
        recommendations.report = { [weak self] in self?.browser?.report($0) }
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
