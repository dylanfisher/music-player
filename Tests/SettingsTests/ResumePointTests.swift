import Foundation
import Testing

@testable import Settings

private func configURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("resume-\(UUID().uuidString)/config.json")
}

@MainActor
private func store(_ url: URL) throws -> ConfigStore<AppSettings> {
    ConfigStore(AppSettings(), fileURL: url, check: { _, _, _ in nil }, creating: true)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@MainActor @Test func aPlayStateIsWrittenAndReadBackAndNothingIsNull() throws {
    let url = configURL()
    let settings = try store(url)
    #expect(settings[\.resume].isEmpty)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("\"playback.resume\": null"))
    let point = ResumePoint(
        track: "music/library/A/01.flac", seconds: 83.5,
        from: "playlist:" + String(repeating: "a", count: 32), source: nil,
        selected: "/Users/me/Music/02.flac", top: "music/library/A/01.flac")
    try settings.set(\.resume, to: point)
    #expect(try store(url)[\.resume] == point)
}

@MainActor @Test func aPlayStateOfAnotherShapeReadsAsNothingAndBlocksNothing() throws {
    for value in [
        #"{"track": "a.flac", "seconds": 3}"#,
        #"{"track": "a.flac", "seconds": -1, "from": null, "source": null, "selected": null, "top": null}"#,
        #"{"track": "a.flac", "seconds": 3, "from": null, "source": null, "selected": null, "top": null, "queue": []}"#,
        #""a.flac""#,
    ] {
        let url = configURL()
        try write(#"{"playback.resume": \#(value), "appearance.glass": true}"#, to: url)
        let settings = try store(url)
        #expect(settings.problems.isEmpty, "\(value)")
        #expect(settings[\.resume].isEmpty, "\(value)")
        #expect(settings[\.glass], "\(value)")
    }
}
