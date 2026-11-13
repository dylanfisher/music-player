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

@MainActor
@Test func anUnaskedSendSaysOnlyAFailureAndSendsNothingUnchanged() async throws {
    let recommendations = Recommendations(databaseURL: URL(fileURLWithPath: "/", isDirectory: true))
    recommendations.readProfile = { LibraryProfile(albums: []) }
    let sends = MarkCalls()
    var fails = false
    recommendations.service = {
        var service = RecommendationsService.unused
        service.sendProfile = { [fails] _ throws(RecommenderError) in
            sends.append("profile")
            if fails {
                throw RecommenderError(
                    service: "http://192.168.1.20:7878/v1/profile",
                    kind: .unreachable(.refused("connection refused")))
            }
            return ProfileReceipt(albums: 0, withReleaseID: 0, queued: 0)
        }
        return service
    }
    var said: [String] = []
    recommendations.say = { said.append($0) }
    recommendations.report = { said.append($0) }
    await recommendations.sendProfileIfChanged().value
    await recommendations.sendProfileIfChanged().value
    #expect(sends.calls == ["profile"])
    #expect(said.isEmpty)
    fails = true
    await recommendations.sendProfile()?.value
    #expect(sends.calls == ["profile", "profile"], "asked, it goes though unchanged")
    #expect(said.last?.contains("couldn't send the library profile: music-recommender at") == true)
    #expect(said.last?.contains("192.168.1.20:7878") == true)
}
