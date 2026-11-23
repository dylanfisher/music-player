import Foundation
import Testing

@testable import Analysis
@testable import Fixtures

/// A copy of the full-band fixture in a folder of its own, its middle bytes passed to `damage`.
private func copy(damaging damage: (inout Data) -> Void = { _ in }) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var data = try Data(
        contentsOf: try analysisFixture(.fullBand, in: try defaultPlaybackFixturesDirectory()))
    damage(&data)
    let url = directory.appendingPathComponent("01 First Song.flac")
    try data.write(to: url)
    return url.path
}

@Test func aFileThatDecodesToItsEndIsntDamaged() async throws {
    let path = try copy()
    defer {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
    #expect(try await damagedAudio([path]).isEmpty)
}

@Test func aFileThatStopsDecodingPartwayIsDamaged() async throws {
    // As the peers' copies were: the header and tags read, then frames that don't decode.
    let path = try copy { data in
        let middle = data.count / 2
        for index in middle..<(middle + 4096) { data[index] ^= 0xFF }
    }
    defer {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
    let damage = try await damagedAudio([path])
    #expect(damage.count == 1)
    #expect(damage.first?.hasPrefix("01 First Song.flac is damaged: it stops decoding") == true)
}

@Test func aFileThatDoesntOpenOrIsGoneIsLeftToTheOtherChecks() async throws {
    // The tag read calls a file that isn't audio damaged (ADR 0210); a missing one may be a
    // share that dropped, which mustn't throw a download away.
    let path = try copy { $0 = Data("not audio".utf8) }
    defer {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
    #expect(try await damagedAudio([path, path + ".missing"]).isEmpty)
}
