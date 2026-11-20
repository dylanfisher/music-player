import Fixtures
import Foundation
import LocalNetwork
import Testing

@testable import Recommendations
@testable import Recommender

// Service Status: the window's link opens music-recommender's status page at the address and
// port set, or beeps and says to set the address.

@MainActor
@Test func serviceStatusOpensTheStatusPageAtTheAddressSet() throws {
    let recommendations = Recommendations(databaseURL: URL(fileURLWithPath: "/", isDirectory: true))
    var page: URL?
    recommendations.statusPage = { page }
    var opened: [URL] = []
    recommendations.open = { opened.append($0) }
    var beeps = 0
    recommendations.beep = { beeps += 1 }
    var said: [String] = []
    recommendations.say = { said.append($0) }
    recommendations.show()
    let link = try #require(recommendations.controller?.statusLink)

    click(link)
    #expect(opened.isEmpty)
    #expect(beeps == 1)
    #expect(said == ["Set music-recommender's address in Settings."])

    page = serviceStatusPage(address: try #require(IPAddress("192.168.1.20")), port: 7878)
    click(link)
    #expect(opened.map(\.absoluteString) == ["http://192.168.1.20:7878/status"])
}

@Test func theStatusPageOfAnIPv6AddressPutsItInBrackets() throws {
    let page = serviceStatusPage(address: try #require(IPAddress("fd00::14")), port: 8000)
    #expect(page.absoluteString == "http://[fd00::14]:8000/status")
}
