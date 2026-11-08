import Foundation
import Testing

@testable import Discogs
@testable import Fixtures

/// A file of two gzip members, each several deflate blocks of text that compresses about as
/// the dumps do.
private func twoMembers(in directory: URL) throws -> (url: URL, text: Data) {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let words = (0..<60_000).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return String(state % 50_000, radix: 36)
    }
    let first = Data(words[..<35_000].joined(separator: " ").utf8)
    let second = Data(words[35_000...].joined(separator: " ").utf8)
    let one = directory.appendingPathComponent("one.gz", isDirectory: false)
    let two = directory.appendingPathComponent("two.gz", isDirectory: false)
    try DiscogsDumpFixture.writeGzip(first, to: one)
    try DiscogsDumpFixture.writeGzip(second, to: two)
    let url = directory.appendingPathComponent("both.gz", isDirectory: false)
    try (try Data(contentsOf: one) + Data(contentsOf: two)).write(to: url)
    return (url, first + second)
}

/// Reads `stream` to its end, and returns what it inflated and its access points.
private func readAll(_ stream: GzipStream) throws -> (Data, [GzipAccessPoint]) {
    var output = Data()
    var points: [GzipAccessPoint] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBufferPointer {
            stream.read($0.baseAddress!, maxLength: $0.count)
        }
        if count < 0 { throw try #require(stream.failure) }
        if count == 0 { break }
        output.append(contentsOf: buffer[..<count])
        if let point = stream.takeAccessPoint() { points.append(point) }
    }
    return (output, points)
}

@Test func aStreamResumedAtAnyAccessPointReadsAndHashesTheRestAsOneFromTheStart() throws {
    let folder = try DumpFolder()
    let (url, text) = try twoMembers(in: folder.directory)
    let straight = try GzipStream(file: url, accessPointBytes: 2048)
    let (whole, points) = try readAll(straight)
    #expect(whole == text)
    let hash = straight.sha256()
    // Points in both members, some with bits of a byte still to read.
    #expect(points.count > 4)
    #expect(points.contains { $0.bits > 0 })
    #expect(points.contains { $0.memberBytes < $0.inflatedOffset })
    for point in points {
        let resumed = try GzipStream(file: url, resumingAt: point)
        let (rest, _) = try readAll(resumed)
        #expect(rest == text.suffix(from: point.inflatedOffset))
        #expect(resumed.isComplete)
        #expect(resumed.sha256() == hash)
    }
}

@Test func aResumedStreamChecksTheMembersTrailer() throws {
    let folder = try DumpFolder()
    let (url, _) = try twoMembers(in: folder.directory)
    let (_, points) = try readAll(try GzipStream(file: url, accessPointBytes: 2048))
    let point = try #require(points.first)
    var wrong = point
    wrong.crc ^= 1
    #expect(throws: CatalogImportError.corrupt(url.lastPathComponent, "incorrect data check")) {
        _ = try readAll(try GzipStream(file: url, resumingAt: wrong))
    }
    var damaged = point
    damaged.sha256State = Data([1, 2, 3])
    #expect(throws: CatalogImportError.self) { try GzipStream(file: url, resumingAt: damaged) }
}
