import Foundation
import Testing

@testable import Library
@testable import Settings

private func temporaryIndex() throws -> (LibraryIndex, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("import-jobs-\(UUID().uuidString)/library.sqlite")
    return (try LibraryIndex(at: url), url)
}

private let moved = ImportStep(
    jobID: 42, releaseID: 4242, kind: .moved, path: "job-42/01 First Song.flac",
    destination: "library/Made-Up Artist/Made-Up Album/01 First Song.flac", sizeBytes: 24_117_248)

@Test func theOutboxHoldsEachReportInOrderUntilItsSent() throws {
    let (index, _) = try temporaryIndex()
    let first = try index.queueImportReport(job: 42, release: 4242, body: #"{"type": "approved"}"#)
    let second = try index.queueImportReport(job: 7, release: 77, body: #"{"type": "rejected"}"#)
    let third = try index.queueImportReport(job: 42, release: 4242, body: #"{"type": "imported"}"#)
    #expect(try index.importReports().map(\.seq) == [first, second, third])
    #expect(
        try index.importReports().first
            == QueuedImportReport(
                seq: first, jobID: 42, releaseID: 4242, body: #"{"type": "approved"}"#))
    try index.removeImportReport(first)
    #expect(
        try index.importReports().map(\.body) == [
            #"{"type": "rejected"}"#, #"{"type": "imported"}"#,
        ])
}

@Test func theLedgerKeepsOneRowPerJobStepAndPath() throws {
    let (index, _) = try temporaryIndex()
    try index.recordImportStep(moved)
    try index.recordImportStep(moved)
    var trashed = moved
    trashed.kind = .trashed
    trashed.path = "library/Made-Up Artist/Made-Up Album/01 First Song.mp3"
    trashed.destination = nil
    try index.recordImportStep(trashed)
    var other = moved
    other.jobID = 43
    try index.recordImportStep(other)
    #expect(try index.importSteps(job: 42) == [moved, trashed])
    try index.forgetImportJob(42)
    #expect(try index.importSteps(job: 42).isEmpty)
    #expect(try index.importSteps(job: 43) == [other])
}

@Test func theLedgerTakesOnlyPathsRelativeToTheirFolder() throws {
    let (index, _) = try temporaryIndex()
    for path in ["/Volumes/music/staging/job-42/1.flac", "job-42/../x.flac", "", "job-42//1.flac"] {
        var step = moved
        step.path = path
        #expect(throws: LibraryError.self, "\(path)") { try index.recordImportStep(step) }
        step = moved
        step.destination = path
        #expect(throws: LibraryError.self, "\(path)") { try index.recordImportStep(step) }
    }
}

@Test func anIndexRebuildKeepsTheImportJobs() throws {
    let (index, url) = try temporaryIndex()
    try index.recordImportStep(moved)
    let seq = try index.queueImportReport(job: 42, release: 4242, body: "{}")
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")
    let rebuilt = try LibraryIndex(at: url)
    #expect(try rebuilt.importSteps(job: 42) == [moved])
    #expect(try rebuilt.importReports().map(\.seq) == [seq])
}
