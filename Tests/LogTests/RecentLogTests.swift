import Foundation
import Testing

@testable import Log

private let logger = moduleLogger()

/// The line comes back with its time, category and level, and only for the categories asked
/// for. A value logged without `privacy: .public` comes back as `<private>`.
@Test func recentLinesHoldThisRunsLines() throws {
    let mark = UUID().uuidString
    logger.error("\(mark, privacy: .public): the device refused \(mark)")
    let lines = try recentLogLines(categories: ["LogTests"], seconds: 60)
    let line = try #require(lines.last { $0.contains(mark) })
    #expect(line.hasSuffix(" LogTests error: \(mark): the device refused <private>"), "\(line)")
    #expect(line.range(of: "^[0-9:.]{12} ", options: .regularExpression) != nil, "\(line)")
    #expect(try !recentLogLines(categories: ["Playback"], seconds: 60).contains(line))
}

private struct Unreadable: Error, CustomStringConvertible {
    var path: String
    var description: String { "\(path): the 'fmt ' chunk is 3 bytes" }
}

/// A failure logged as the playback modules log one: the error's text public without the
/// path, which the line has only as a hash (ADR 0118).
@Test func aFailureReadsBackWithItsErrorAndOnlyAHashOfItsPath() throws {
    let path = "/music/\(UUID().uuidString)/Album/01 Track.dsf"
    let error = Unreadable(path: path)
    #expect(logText(error, without: path) == "the track's file: the 'fmt ' chunk is 3 bytes")
    let mark = UUID().uuidString
    logger.error(
        "\(mark, privacy: .public) \(path, privacy: .private(mask: .hash)): \(logText(error, without: path), privacy: .public)"
    )
    let lines = try recentLogLines(categories: ["LogTests"], seconds: 60)
    let line = try #require(lines.last { $0.contains(mark) })
    #expect(line.hasSuffix(": the track's file: the 'fmt ' chunk is 3 bytes"), "\(line)")
    #expect(!line.contains("Album") && !line.contains("<private>"), "\(line)")
    #expect(line.contains("hash"), "\(line)")
}
