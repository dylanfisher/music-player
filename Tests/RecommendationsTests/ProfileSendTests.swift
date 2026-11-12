import Foundation
import Testing

@testable import Recommendations
@testable import Recommender

@MainActor
@Test func sendingTheProfileSaysWhatTheServiceKeptAndQueued() async throws {
    let recommendations = Recommendations(databaseURL: URL(fileURLWithPath: "/", isDirectory: true))
    let profile = LibraryProfile(albums: [])
    recommendations.readProfile = { profile }
    recommendations.service = {
        var service = RecommendationsService.unused
        service.sendProfile = { _ in ProfileReceipt(albums: 6541, withReleaseID: 1741, queued: 12) }
        return service
    }
    var said: [String] = []
    recommendations.say = { said.append($0) }
    await recommendations.sendProfile()?.value
    #expect(
        said == [
            "Sending the library profile…",
            "Sent 6,541 albums, 1,741 with a release id; 12 newly queued for the community sync",
        ])
}
