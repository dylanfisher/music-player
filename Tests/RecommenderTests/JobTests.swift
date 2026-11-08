import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Recommender
@testable import Settings

/// The contract's example job, with its id, revision and state changed.
private func jobJSON(id: Int = 42, revision: Int = 1093, state: String = "staged") throws -> String
{
    try fixture("job.json")
        .replacingOccurrences(of: #""id": 42"#, with: #""id": \#(id)"#)
        .replacingOccurrences(of: #""revision": 1093"#, with: #""revision": \#(revision)"#)
        .replacingOccurrences(of: #""state": "staged""#, with: #""state": "\#(state)""#)
}

private func jobReply(_ job: String) -> String { #"{"ok": true, "job": \#(job)}"# }

private func page(
    epoch: String = "e1", revision: Int = 0, reset: Bool = false, more: Bool = false,
    _ jobs: [String]
) -> String {
    #"{"ok": true, "epoch": "\#(epoch)", "revision": \#(revision), "reset": \#(reset), "more": \#(more), "jobs": [\#(jobs.joined(separator: ","))]}"#
}

private func decodedPage(_ text: String) throws -> JobPage {
    try decodeReply(Array(text.utf8), as: JobPage.self)
}

/// `text` parsed, to compare JSON whatever its spacing and key order.
private func json(_ text: String) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
}

private let snapshot = ReleaseSnapshot(
    releaseID: 4242, artist: "Made-Up Artist", title: "Made-Up Album", year: 1999,
    tracklists: [
        [
            .init(position: "1", title: "First Song", seconds: 245),
            .init(position: "2", title: "Second Song", seconds: nil),
        ]
    ])

@Test func theContractsJobDecodesWhole() throws {
    let job = try decodeReply(Array(jobReply(try jobJSON()).utf8), as: JobReply.self).job
    #expect(job.id == 42 && job.revision == 1093)
    #expect(job.source == .upgrade && job.formatPolicy == .flac && job.state == .staged)
    #expect(
        job.release
            == .init(releaseID: 4242, artist: "Made-Up Artist", title: "Made-Up Album", year: 1999))
    #expect(job.failedStage == nil && job.reason == nil && job.nextAttemptAt == nil)
    #expect(job.candidate?.format == .flac && job.candidate?.bitrateKbps == nil)
    #expect(job.candidate?.sampleRateHz == 44100 && job.candidate?.tracklist == 0)
    #expect(
        job.files.last == .init(name: "02 - Second Song.flac", sizeBytes: 31_457_280, position: "2")
    )
    #expect(job.stagedPath == "job-42")
    #expect(job.tagging == .init(status: .clean, reasons: []))
    #expect(
        job.lease == nil && job.review == .init(machine: "Living Room", expiresAt: 1_794_150_000))
    #expect(job.upgrade?.oldPaths == ["library/Made-Up Artist/Made-Up Album/01 First Song.mp3"])
    #expect(!job.cleanupPending && job.createdAt == 1_794_060_000)
}

@Test func anUnknownStateIsAnErrorOfItsOwnNeverASkippedJob() throws {
    let text = page([
        try jobJSON(id: 1, revision: 1), try jobJSON(id: 2, revision: 2, state: "paused"),
    ])
    #expect(throws: RecommenderError.Kind.unknownState("paused")) { try decodedPage(text) }
}

@Test func aJobWithAFieldMissingUnknownOrOutOfTheContractIsUnreadable() throws {
    let job = try jobJSON()
    for broken in [
        job.replacingOccurrences(of: #""lease": null,"#, with: ""),
        job.replacingOccurrences(of: #""lease": null,"#, with: #""lease": null, "extra": 1,"#),
        job.replacingOccurrences(of: #""format": "flac""#, with: #""format": "aac""#),
        job.replacingOccurrences(of: #""source": "upgrade""#, with: #""source": "web""#),
        job.replacingOccurrences(of: #""status": "clean""#, with: #""status": "done""#),
        job.replacingOccurrences(of: #""expires_at": 1794150000"#, with: #""expires_at": "soon""#),
    ] {
        do throws(RecommenderError.Kind) {
            _ = try decodeReply(Array(jobReply(broken).utf8), as: JobReply.self)
            Issue.record("decoded \(broken)")
        } catch {
            guard case .unreadable = error else {
                Issue.record("\(error)")
                continue
            }
        }
    }
}

@Test func createSendsTheContractsShape() async throws {
    let stub = try await StubService([(200, jobReply(try jobJSON(state: "queued")))])
    defer { stub.stop() }
    let job = try await stub.client.create(snapshot, .manual(.flac))
    #expect(job.state == .queued)
    let request = try #require(stub.requests.first)
    #expect(request.head.hasPrefix("POST /v1/downloads/create "))
    #expect(try json(request.bodyText) == json(try fixture("create.json")))
}

@Test func anUpgradeSendsWhatItReplacesWithALosslessPolicy() async throws {
    #expect(JobOrder.LosslessPolicy.allCases.map(\.formatPolicy) == [.flac, .lossless])
    let stub = try await StubService([(200, jobReply(try jobJSON()))])
    defer { stub.stop() }
    let upgrade = DownloadJob.Upgrade(currentQuality: "MP3 320", oldPaths: ["library/a/b/1.mp3"])
    _ = try await stub.client.create(snapshot, .upgrade(upgrade, .lossless))
    let body = try #require(stub.requests.first).json
    #expect(body["format_policy"] as? String == "lossless")
    #expect(body["source"] as? String == "upgrade")
    #expect(
        body["upgrade"] as? NSDictionary
            == ["current_quality": "MP3 320", "old_paths": ["library/a/b/1.mp3"]])
}

@Test func aReleaseAlreadyQueuedIsRefusedWithItsJob() async throws {
    let stub = try await StubService([
        (200, #"{"ok": false, "error": {"code": "already_active", "message": "m", "job_id": 7}}"#)
    ])
    defer { stub.stop() }
    let client = try stub.client
    let error = await caught { () async throws(RecommenderError) in
        try await client.create(snapshot, .manual(.any))
    }
    guard case .refused(let refusal) = error?.kind else {
        Issue.record("\(String(describing: error))")
        return
    }
    #expect(refusal.code == .alreadyActive && refusal.jobID == 7)
}

@Test func retryCancelAndHandoffSendTheirBodies() async throws {
    let events: [(HandoffEvent, String)] = [
        (.lease, #"{"type": "lease"}"#),
        (.releaseLease, #"{"type": "release_lease"}"#),
        (
            .tagging(.init(status: .discrepancy, reasons: ["a bonus track"])),
            #"{"type": "tagging", "status": "discrepancy", "reasons": ["a bonus track"]}"#
        ),
        (.claim(takeOver: false), #"{"type": "claim"}"#),
        (.claim(takeOver: true), #"{"type": "claim", "take_over": true}"#),
        (.release, #"{"type": "release"}"#),
        (.approved, #"{"type": "approved"}"#),
        (.importing, #"{"type": "importing"}"#),
        (.imported, #"{"type": "imported"}"#),
        (.rejected, #"{"type": "rejected"}"#),
        (
            .failed(.move, reason: "no room"),
            #"{"type": "failed", "stage": "move", "reason": "no room"}"#
        ),
    ]
    let reply = jobReply(try jobJSON())
    let stub = try await StubService(Array(repeating: (200, reply), count: 3 + events.count))
    defer { stub.stop() }
    let client = try stub.client
    _ = try await client.retry(42, policy: .lossless)
    _ = try await client.retry(42)
    _ = try await client.cancel(42)
    for (event, _) in events { _ = try await client.handoff(42, machine: "Living Room", event) }
    let requests = stub.requests
    #expect(requests[0].head.hasPrefix("POST /v1/downloads/retry "))
    #expect(try requests[0].json == json(#"{"id": 42, "format_policy": "lossless"}"#))
    #expect(try requests[1].json == json(#"{"id": 42}"#))
    #expect(requests[2].head.hasPrefix("POST /v1/downloads/cancel "))
    #expect(try requests[2].json == json(#"{"id": 42}"#))
    for (index, (_, expected)) in events.enumerated() {
        let request = requests[3 + index]
        #expect(request.head.hasPrefix("POST /v1/downloads/handoff "))
        #expect(
            try request.json
                == json(#"{"id": 42, "machine": "Living Room", "event": \#(expected)}"#),
            "\(expected)")
    }
}

@Test func theListPagesUntilThereIsNoMore() async throws {
    let stub = try await StubService([
        (
            200,
            page(
                revision: 9, more: true,
                [try jobJSON(id: 1, revision: 5), try jobJSON(id: 2, revision: 7)])
        ),
        (200, page(revision: 9, [try jobJSON(id: 1, revision: 9, state: "searching")])),
    ])
    defer { stub.stop() }
    let jobs = try await stub.client.refreshed(DownloadJobs())
    #expect(stub.requests.count == 2)
    #expect(try stub.requests[0].json == json(#"{"epoch": null, "after": 0}"#))
    #expect(try stub.requests[1].json == json(#"{"epoch": "e1", "after": 7}"#))
    #expect(stub.requests[0].head.hasPrefix("POST /v1/downloads/list "))
    #expect(jobs.epoch == "e1" && jobs.after == 9)
    #expect(jobs.rows.keys.sorted() == [1, 2])
    #expect(jobs.rows[1]?.state == .searching)
}

@Test func aResetDropsEveryRowWhereverItComes() throws {
    var jobs = DownloadJobs()
    try jobs.take(
        decodedPage(
            page(
                epoch: "old", [try jobJSON(id: 1, revision: 40), try jobJSON(id: 2, revision: 50)]))
    )
    #expect(jobs.rows.count == 2 && jobs.after == 50)

    // The service's database was rebuilt: a new epoch, and revisions from the start.
    try jobs.take(decodedPage(page(epoch: "new", reset: true, [try jobJSON(id: 3, revision: 2)])))
    #expect(jobs.rows.keys.sorted() == [3] && jobs.after == 2 && jobs.epoch == "new")

    // A reset with nothing in the store empties the rows and starts again from 0.
    try jobs.take(decodedPage(page(epoch: "newer", reset: true, [])))
    #expect(jobs.rows.isEmpty && jobs.after == 0)
}

@Test func aResetOnALaterPageDropsTheRowsOfTheEarlierOnes() async throws {
    let stub = try await StubService([
        (200, page(epoch: "e1", more: true, [try jobJSON(id: 1, revision: 51)])),
        (200, page(epoch: "e2", reset: true, [try jobJSON(id: 9, revision: 1)])),
    ])
    defer { stub.stop() }
    var start = DownloadJobs()
    start.epoch = "e1"
    start.after = 50
    let jobs = try await stub.client.refreshed(start)
    #expect(jobs.rows.keys.sorted() == [9] && jobs.after == 1 && jobs.epoch == "e2")
}

@Test func aPageThatDoesntAdvanceIsUnreadable() throws {
    var jobs = DownloadJobs()
    try jobs.take(decodedPage(page([try jobJSON(id: 1, revision: 10)])))
    let before = jobs
    for broken in [
        page(more: true, []),
        page([try jobJSON(id: 2, revision: 10)]),
        page([try jobJSON(id: 2, revision: 12), try jobJSON(id: 3, revision: 11)]),
        page(epoch: "other", [try jobJSON(id: 2, revision: 12)]),
    ] {
        #expect(throws: RecommenderError.Kind.self, "\(broken)") {
            try jobs.take(decodedPage(broken))
        }
        #expect(jobs == before)
    }
}

@Test func anOutboxReportReadsBackAsTheEventItWas() throws {
    let events: [HandoffEvent] = [
        .lease, .releaseLease, .tagging(.init(status: .discrepancy, reasons: ["a bonus track"])),
        .tagging(.init(status: .clean, reasons: [])), .claim(takeOver: false),
        .claim(takeOver: true), .release, .approved, .importing, .imported, .rejected,
        .failed(.carry, reason: "no room"),
    ]
    for event in events {
        #expect(try HandoffEvent(json: event.json) == event)
    }
    #expect(throws: (any Error).self) { try HandoffEvent(json: #"{"type": "approved", "x": 1}"#) }
    #expect(throws: (any Error).self) { try HandoffEvent(json: #"{"type": "shrug"}"#) }
}

/// The service refuses a string over this many characters (`MAX_STRING_CHARS` in its API).
private let serviceLimit = 1000

/// The strings of an event's encoding that carry text: a failure's reason, a tagging's reasons.
private func texts(_ event: HandoffEvent) throws -> [String] {
    let object =
        try #require(
            try JSONSerialization.jsonObject(with: Data(event.json.utf8)) as? [String: Any])
    return (object["reason"] as? String).map { [$0] } ?? (object["reasons"] as? [String] ?? [])
}

@Test func aReasonOverTheServicesLimitIsCutWithAnEllipsis() throws {
    let long = String(repeating: "x", count: 5000)
    let failed = try texts(.failed(.move, reason: long))
    #expect(failed.count == 1)
    #expect(failed[0].unicodeScalars.count == serviceLimit)
    #expect(failed[0] == String(repeating: "x", count: serviceLimit - 1) + "…")

    let reasons = try texts(.tagging(.init(status: .error, reasons: ["short", long])))
    #expect(reasons[0] == "short")
    #expect(reasons[1].unicodeScalars.count == serviceLimit)
}

@Test func aReasonAtTheLimitIsLeftAlone() throws {
    let exact = String(repeating: "é", count: serviceLimit)
    #expect(try texts(.failed(.tag, reason: exact)) == [exact])
}

@Test func aCutNeverSplitsACharacter() throws {
    // A family emoji is five scalars: the first falls within the budget and the rest don't,
    // so all of it goes.
    let family = "👨‍👩‍👧"
    let long = String(repeating: "x", count: serviceLimit - 4) + family + family
    let cut = try #require(try texts(.failed(.delete, reason: long)).first)
    #expect(cut == String(repeating: "x", count: serviceLimit - 4) + "…")
    #expect(cut.unicodeScalars.count <= serviceLimit)
}

@Test func aCutEventStillReadsBackFromTheOutbox() throws {
    let event = HandoffEvent.failed(.carry, reason: String(repeating: "y", count: 3000))
    let read = try HandoffEvent(json: event.json)
    #expect(read.json == event.json)
}
