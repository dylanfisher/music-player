import Foundation
import Testing

@testable import Discogs
@testable import Downloads
@testable import Library
@testable import Recommender
@testable import Settings

// Approve… takes the review claim before it looks at the job, so each way out before the sheet
// decides gives the claim back.

private struct NoFolder: Error {}

/// Downloads started on `service`, with its first poll taken, and a staging folder that is
/// there only if `places` says so.
@MainActor
func started(
    _ service: DownloadsService, places: @escaping @Sendable () async throws -> ImportPlaces
) async throws -> (Downloads, Downloads.Session) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let database = folder.appendingPathComponent("library.sqlite", isDirectory: false)
    _ = try LibraryIndex(at: database)
    let downloads = Downloads()
    downloads.start(
        Downloads.Setup(
            machine: FakeService.machine, service: service, databaseURL: database,
            dataDirectory: folder, catalog: folder.appendingPathComponent("none.sqlite"),
            mapping: DiscogsPreset.oneToOne.mapping, share: nil, places: places,
            trash: { _ in nil }, carry: { _ in MoveListImport(problems: []) }, rescan: { _ in }))
    let session = try #require(downloads.session)
    await eventually("the coordinator") { session.coordinator != nil }
    return (downloads, session)
}

private let clean = DownloadJob.Tagging(status: .clean, reasons: [])

@MainActor
@Test func aJobThatCantBeApprovedGivesTheClaimBack() async throws {
    let service = FakeService([job(1)])
    let (downloads, session) = try await started(service.service) { throw NoFolder() }
    await downloads.review(try #require(service.job(1)), session, resuming: false)
    #expect(service.eventTypes.suffix(2) == ["claim", "release"])
    #expect(service.job(1)?.review == nil)
    downloads.stop()
}

@MainActor
@Test func aMissingStagingFolderGivesTheClaimBack() async throws {
    let service = FakeService([job(1) { $0.tagging = clean }])
    let (downloads, session) = try await started(service.service) { throw NoFolder() }
    await downloads.review(try #require(service.job(1)), session, resuming: false)
    #expect(service.eventTypes.suffix(2) == ["claim", "release"])
    #expect(service.job(1)?.review == nil)
    downloads.stop()
}

@MainActor
@Test func aSheetThatCantShowGivesTheClaimBack() async throws {
    let service = FakeService([job(1) { $0.tagging = clean }])
    let nowhere = FileManager.default.temporaryDirectory.path + "/\(UUID().uuidString)"
    let (downloads, session) = try await started(service.service) {
        ImportPlaces(stagingRoot: nowhere, libraryFolder: nowhere, shareRoot: nowhere)
    }
    // The window was never shown, so there is nothing to put the sheet on.
    await downloads.review(try #require(service.job(1)), session, resuming: false)
    #expect(service.eventTypes.suffix(2) == ["claim", "release"])
    #expect(service.job(1)?.review == nil)
    downloads.stop()
}

@MainActor
@Test func aReviewCancelledWhileItChecksShowsNoSheetAndGivesTheClaimBack() async throws {
    let service = FakeService([job(1) { $0.tagging = clean }])
    let nowhere = FileManager.default.temporaryDirectory.path + "/\(UUID().uuidString)"
    let (downloads, session) = try await started(service.service) {
        ImportPlaces(stagingRoot: nowhere, libraryFolder: nowhere, shareRoot: nowhere)
    }
    downloads.show()
    let listed = try #require(service.job(1))
    let review = Task { await downloads.review(listed, session, resuming: false) }
    review.cancel()
    await review.value
    await eventually("the claim given back") { service.job(1)?.review == nil }
    #expect(downloads.window?.attachedSheet == nil)
    downloads.window?.close()
    downloads.stop()
}

@MainActor
@Test func aReviewCancelledWhileItClaimsGivesTheClaimBackIfTheServiceTookIt() async throws {
    let fake = FakeService([job(1) { $0.tagging = clean }])
    var service = fake.service
    let handoff = service.handoff
    // The service takes the claim, but the cancelled request throws before the reply arrives.
    service.handoff = { id, event throws(RecommenderError) in
        let answer = try await handoff(id, event)
        if case .claim = event, Task.isCancelled {
            throw RecommenderError(service: "fake", kind: .cancelled)
        }
        return answer
    }
    let (downloads, session) = try await started(service) { throw NoFolder() }
    let listed = try #require(fake.job(1))
    let review = Task { await downloads.review(listed, session, resuming: false) }
    review.cancel()
    await review.value
    await eventually("the claim given back") { fake.job(1)?.review == nil }
    downloads.stop()
}

@MainActor
@Test func aSecondApproveWhileOneIsInFlightIsIgnored() async throws {
    let service = FakeService([job(1) { $0.tagging = clean }])
    let (downloads, session) = try await started(service.service) { throw NoFolder() }
    let first = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 60_000_000_000) }
    downloads.reviewing = first
    downloads.startReview(try #require(service.job(1)), session, resuming: false)
    #expect(downloads.reviewing == first)
    #expect(!first.isCancelled)
    #expect(service.eventTypes.isEmpty)
    downloads.cancelReview()
    #expect(first.isCancelled)
    downloads.stop()
}

@MainActor
@Test func closingTheWindowOrStoppingCancelsTheReviewInProgress() async throws {
    let service = FakeService([job(1) { $0.tagging = clean }])
    let (downloads, _) = try await started(service.service) { throw NoFolder() }
    downloads.show()
    let closed = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 60_000_000_000) }
    downloads.reviewing = closed
    downloads.window?.close()
    #expect(closed.isCancelled)
    #expect(downloads.reviewing == nil)

    let stopped = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 60_000_000_000) }
    downloads.reviewing = stopped
    downloads.stop()
    #expect(stopped.isCancelled)
}

@Test func thisMacsNameIsTheIndexsMachineIDAndStaysTheSame() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "machine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let database = folder.appendingPathComponent("library.sqlite", isDirectory: false)
    let id = try LibraryIndex(at: database).machineID()
    #expect(try await Downloads.machineName(databaseURL: database) == id)
    #expect(try await Downloads.machineName(databaseURL: database) == id)
    #expect(!id.isEmpty && id.count <= Downloads.machineNameCap)
}
