import Foundation
import Testing

@testable import Settings

private func decode(_ json: String) throws -> BrowserSource {
    try JSONDecoder().decode(BrowserSource.self, from: Data(json.utf8))
}

@Test func aSourceIsSavedAsOneString() throws {
    for source in [BrowserSource.folder("/Volumes/music"), .playlist(42), .history] {
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(BrowserSource.self, from: data) == source)
    }
    #expect(try decode(#""playlist:7""#) == .playlist(7))
    #expect(try decode(#""/a/b""#) == .folder("/a/b"))
    #expect(try decode(#""history""#) == .history)
}

@Test func aSourceThatIsntAPathPlaylistOrHistoryFails() {
    for json in [#""music""#, #""playlist:""#, #""playlist:x""#, #""History""#, "3", "{}"] {
        #expect(throws: DecodingError.self, "\(json)") { try decode(json) }
    }
}
