import Foundation
import Testing

@testable import CacheFolder

/// What a folder reported, for the tests to read.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
}

private func scratch(
    capacityBytes: Int = 1_000_000, capacityFiles: Int = .max, reports: Reports = Reports()
) -> CacheFolder {
    CacheFolder(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "cache-folder-\(UUID().uuidString)", isDirectory: true),
        noun: "thing", capacityBytes: capacityBytes, capacityFiles: capacityFiles,
        trimEveryBytes: .max, report: reports.add)
}

@Test func storedBytesComeBackOnlyForTheirOwnKey() {
    let folder = scratch()
    #expect(folder.data(["a", "1"]) == nil)
    folder.store(Data([1, 2, 3]), ["a", "1"], of: "a")
    #expect(folder.data(["a", "1"]) == Data([1, 2, 3]))
    #expect(folder.data(["a", "2"]) == nil)
}

@Test func aDiscardedFileIsGoneAndSaysWhy() {
    let reports = Reports()
    let folder = scratch(reports: reports)
    folder.store(Data([1]), ["a"], of: "a")
    folder.discard(["a"])
    #expect(folder.data(["a"]) == nil)
    #expect(
        reports.all == [
            "the stored thing \(folder.fileURL(["a"]).path) doesn't decode; removing it"
        ])
}

@Test func theTrimRemovesTheLeastRecentlyUsedPastEitherCapacity() throws {
    for (bytes, files) in [(2, Int.max), (1_000, 2)] {
        let folder = scratch(capacityBytes: bytes, capacityFiles: files)
        for (offset, name) in ["old", "used", "new"].enumerated() {
            folder.store(Data([1]), [name], of: name)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(offset) * 1_000)],
                ofItemAtPath: folder.fileURL([name]).path)
        }
        // A read marks "old" used, so "used" is now the oldest.
        #expect(folder.data(["old"]) != nil)
        folder.trim()
        #expect(folder.data(["used"]) == nil)
        #expect(folder.data(["old"]) != nil && folder.data(["new"]) != nil)
    }
}

@Test func onlyTheFirstFailuresOfASessionAreReported() {
    let reports = Reports()
    let folder = scratch(reports: reports)
    for number in 0..<(CacheFolder.reportedFailures + 5) { folder.fail("failure \(number)") }
    #expect(reports.all.count == CacheFolder.reportedFailures)
    #expect(reports.all.last == "failure \(CacheFolder.reportedFailures - 1)")
}
