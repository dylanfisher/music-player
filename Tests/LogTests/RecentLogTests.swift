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
