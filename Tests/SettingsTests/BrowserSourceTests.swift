import Foundation
import Testing

@testable import Settings

private func decode(_ json: String) throws -> BrowserSource {
    try JSONDecoder().decode(BrowserSource.self, from: Data(json.utf8))
}

@Test func aSourceIsSavedAsOneString() throws {
    let periods = [StatsPeriod.week, .month, .year, .chosenYear(2024), .all]
    for source in [BrowserSource.playlist(42), .history, .timeline]
        + HealthCheck.allCases.map(BrowserSource.health)
        + periods.map(BrowserSource.stats) + [.plays(PlaySpan(start: 100, end: 200))]
    {
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(BrowserSource.self, from: data) == source)
    }
    #expect(try decode(#""playlist:7""#) == .playlist(7))
    #expect(try decode(#""history""#) == .history)
    #expect(try decode(#""timeline""#) == .timeline)
    #expect(try decode(#""health:noArt""#) == .health(.noArt))
    #expect(try decode(#""stats:month""#) == .stats(.month))
    #expect(try decode(#""stats:2019""#) == .stats(.chosenYear(2019)))
    #expect(
        try decode(#""plays:1700000000-1700086400""#)
            == .plays(PlaySpan(start: 1_700_000_000, end: 1_700_086_400)))
    #expect(BrowserSource.plays(PlaySpan(start: 1, end: 2)).listsPlays)
    #expect(BrowserSource.timeline.listsPlays)
    #expect(!BrowserSource.stats(.all).listsPlays)
}

@Test func aSourceThatIsntAPlaylistHistoryOrCheckFails() {
    for json in [
        #""music""#, #""/a/b""#, #""playlist:""#, #""playlist:x""#, #""History""#, #""Timeline""#,
        #""health:""#,
        #""health:NoArt""#, #""health:noArt ""#, "3", "{}",
        #""stats""#, #""stats:""#, #""stats:Month""#, #""stats:decade""#, #""plays:""#,
        #""plays:5-5""#, #""plays:9-2""#, #""plays:-1-2""#, #""plays:1-2-3""#, #""plays:a-b""#,
    ] {
        #expect(throws: DecodingError.self, "\(json)") { try decode(json) }
    }
}
