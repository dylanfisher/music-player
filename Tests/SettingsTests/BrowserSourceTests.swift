import Foundation
import Testing

@testable import Settings

private func decode(_ json: String) throws -> BrowserSource {
    try JSONDecoder().decode(BrowserSource.self, from: Data(json.utf8))
}

@Test func aSourceIsSavedAsOneString() throws {
    for source in [BrowserSource.playlist(42), .history, .timeline]
        + HealthCheck.allCases.map(BrowserSource.health)
    {
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(BrowserSource.self, from: data) == source)
    }
    #expect(try decode(#""playlist:7""#) == .playlist(7))
    #expect(try decode(#""history""#) == .history)
    #expect(try decode(#""timeline""#) == .timeline)
    #expect(try decode(#""health:noArt""#) == .health(.noArt))
}

@Test func aSourceThatIsntAPlaylistHistoryOrCheckFails() {
    for json in [
        #""music""#, #""/a/b""#, #""playlist:""#, #""playlist:x""#, #""History""#, #""Timeline""#,
        #""health:""#,
        #""health:NoArt""#, #""health:noArt ""#, "3", "{}",
    ] {
        #expect(throws: DecodingError.self, "\(json)") { try decode(json) }
    }
}
