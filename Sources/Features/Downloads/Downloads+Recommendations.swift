import Recommender

extension Downloads {
    /// Download… in the Recommendations window (phase 86, ADR 0205): shows the window with the
    /// queue sheet for `albums`, so their snapshots, the format policy and the errors are
    /// those of every other queue.
    package func queue(recommended albums: [RecommendationPage.Album]) {
        show()
        guard let session, session.canTag else {
            return alert(
                "Recommendations can't be downloaded yet",
                ["Downloads need the service's address and token and this Mac's Discogs catalog."])
        }
        guard session.model.connection == .answering else {
            return alert(
                "Recommendations can't be downloaded yet", ["music-recommender isn't answering."])
        }
        chooseAndQueue(
            heading: "From Recommendations",
            note: "The albums selected in Recommendations, each downloaded as its release.",
            QueueChoice.recommended(albums), upgrade: false, tickingAll: true)
    }
}
