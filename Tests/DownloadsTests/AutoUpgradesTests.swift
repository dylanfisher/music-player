import Foundation
import Testing

@testable import Analysis
@testable import Downloads
@testable import Library
@testable import Recommender

// Upgrade to FLAC Automatically (ADR 0200), through the stand-in service: never more than N of
// its own jobs in flight, the best candidates first, a job that found nothing cancelled and
// counted, and a copy that isn't clean requeued.

private let day = 86_400.0

/// A lossy album of `release`, played `plays` times at `kbps`.
private func candidate(_ release: Int, plays: Int = 0, kbps: Int = 320) -> UpgradeCandidate {
    UpgradeCandidate(
        albumID: Int64(release), title: "Album \(release)", artist: "Made-Up Artist",
        releaseID: release, sharePaths: ["library/\(release)/01.mp3"],
        quality: "MP3 \(kbps) kbps", kbps: kbps, plays: plays)
}

private func mine(_ id: Int, release: Int, epoch: String = "e1") -> AutoUpgradeJob {
    AutoUpgradeJob(epoch: epoch, jobID: id, releaseID: release)
}

/// The service's job `id` of `release` in `state`.
private func listed(
    _ id: Int, release: Int, _ state: JobState, _ change: (inout DownloadJob) -> Void = { _ in }
) -> DownloadJob {
    job(id, state) {
        $0.release.releaseID = release
        change(&$0)
    }
}

@Test func eachOfItsJobsIsSettledByItsState() {
    let discrepancy = DownloadJob.Tagging(status: .discrepancy, reasons: ["a bonus track"])
    let jobs = [
        listed(1, release: 11, .imported), listed(2, release: 12, .rejected),
        listed(3, release: 13, .cancelled), listed(4, release: 14, .notFound),
        listed(5, release: 15, .failed) { $0.failedStage = .download },
        listed(6, release: 16, .failed) { $0.failedStage = .move },
        listed(7, release: 17, .staged) { $0.tagging = discrepancy },
        listed(8, release: 18, .staged) {
            $0.tagging = discrepancy
            $0.lease = DownloadJob.Hold(machine: "Kitchen", expiresAt: 0)
        },
        listed(9, release: 19, .staged), listed(10, release: 20, .downloading),
        listed(12, release: 22, .staged) { $0.tagging = clean },
        listed(13, release: 23, .staged) { $0.tagging = clean },
        listed(14, release: 24, .staged) {
            $0.tagging = DownloadJob.Tagging(status: .error, reasons: ["unreadable"])
        },
        listed(15, release: 25, .staged),
    ]
    let own =
        (1...10).map { mine($0, release: 10 + $0) } + [
            mine(11, release: 21), mine(1, release: 11, epoch: "e0"),
        ] + (12...15).map { mine($0, release: 10 + $0) }
    let (steps, inFlight) = AutoUpgrades.steps(
        own: own, jobs: Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) }),
        epoch: "e1", notClean: [9], approvable: [12])
    #expect(
        steps == [
            .forget(own[0]), .miss(own[1]), .miss(own[2]), .cancelThenMiss(own[3]),
            .cancelThenMiss(own[4]), .requeue(own[6]), .requeue(own[8]), .forget(own[10]),
            .forget(own[11]),
        ])
    // Both requeued, held, downloading, clean for Approve Safe and untagged; not failed at
    // move, left for review or a tagging error.
    #expect(inFlight == 6)
}

private let clean = DownloadJob.Tagging(status: .clean, reasons: [])

@MainActor
@Test func aCopyLeftForTheOwnerHoldsNoSlot() async throws {
    let fake = FakeService()
    let (downloads, session) = try await upgrading(
        fake, Library([candidate(1, plays: 9), candidate(2)]), inFlight: 1)
    downloads.autoUpgrade = true
    await eventually("queued") { fake.created.count == 1 }
    await settled(downloads)
    fake.put(listed(1, release: 1, .staged) { $0.tagging = clean })
    await session.model.poll()
    await eventually("the next queued") { fake.created.count == 2 }
    #expect(fake.created.last?.release == 2, "Approve Safe is off: the copy waits for review")
    downloads.stop()
}

@Test func theCandidatesLeaveOutMarkedSetAsideWaitingAndQueuedAlbums() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let candidates = (1...7).map { candidate($0, plays: $0) }
    let chosen = AutoUpgrades.next(
        candidates,
        jobs: [listed(1, release: 6, .downloading), listed(2, release: 5, .imported)],
        never: [7],
        misses: [
            4: UpgradeMiss(misses: 4, retryAt: nil),
            3: UpgradeMiss(misses: 1, retryAt: now.timeIntervalSince1970 + day),
            2: UpgradeMiss(misses: 2, retryAt: now.timeIntervalSince1970 - 1),
        ],
        skipped: [1], now: now, room: 3)
    #expect(chosen.map(\.releaseID) == [5, 2], "an ended job and a wait that's over don't count")
    #expect(
        AutoUpgrades.next(
            candidates, jobs: [], never: [], misses: [:], skipped: [], now: now, room: 0
        ).isEmpty)
}

@Test func twoAlbumsOfOneReleaseMakeOneChoice() {
    let twin = UpgradeCandidate(
        albumID: 9, title: "Album 1", artist: "Made-Up Artist", releaseID: 1,
        sharePaths: ["library/1 copy/01.mp3"], quality: "MP3 320 kbps", kbps: 320, plays: 0)
    let chosen = AutoUpgrades.next(
        [candidate(1, plays: 5), twin, candidate(2)], jobs: [], never: [], misses: [:],
        skipped: [], now: Date(), room: 3)
    #expect(chosen.map(\.albumID) == [1, 2])
}

/// The albums the index would list now.
private final class Library: @unchecked Sendable {
    private let lock = NSLock()
    private var albums: [UpgradeCandidate]

    init(_ albums: [UpgradeCandidate]) { self.albums = albums }

    var candidates: [UpgradeCandidate] { lock.withLock { albums } }

    /// The album of `release` upgraded: no longer a candidate.
    func upgraded(_ release: Int) { lock.withLock { albums.removeAll { $0.releaseID == release } } }
}

/// Downloads started on the share, able to tag, with `library`'s candidates to upgrade and a
/// snapshot for any release.
@MainActor
private func upgrading(_ fake: FakeService, _ library: Library, inFlight: Int = 3)
    async throws -> (Downloads, Downloads.Session)
{
    let nowhere = FileManager.default.temporaryDirectory.path + "/\(UUID().uuidString)"
    let (downloads, session) = try await started(fake.service, share: "smb://nas/music") {
        ImportPlaces(stagingRoot: nowhere, libraryFolder: nowhere, shareRoot: nowhere)
    }
    session.canTag = true
    downloads.upgradeCandidates = { _, _ in library.candidates }
    downloads.releaseSnapshot = { release, _ in
        ReleaseSnapshot(
            releaseID: release, artist: "Made-Up Artist", title: "Album \(release)", year: nil,
            tracklists: [[ReleaseSnapshot.Track(position: "1", title: "One", seconds: 200)]])
    }
    downloads.autoUpgradesInFlight = inFlight
    await eventually("the first poll") { session.model.connection == .answering }
    return (downloads, session)
}

@MainActor
private func settled(_ downloads: Downloads) async {
    await eventually("the pass done") { downloads.upgrading == nil }
}

@MainActor
@Test func itKeepsNInFlightBestFirstAndQueuesTheNextAsOneLands() async throws {
    let fake = FakeService()
    let candidates = [
        candidate(1, plays: 50, kbps: 320), candidate(2, plays: 50, kbps: 128),
        candidate(3, plays: 0, kbps: 128), candidate(4, plays: 200, kbps: 256),
        candidate(5, plays: 0, kbps: 320),
    ]
    let library = Library(candidates)
    let (downloads, session) = try await upgrading(fake, library)
    downloads.autoUpgrade = true
    await eventually("three queued") { fake.created.count == 3 }
    await settled(downloads)
    #expect(fake.created.map(\.release) == [4, 2, 1])
    #expect(
        fake.created.allSatisfy {
            if case .upgrade(_, .flac) = $0.order { true } else { false }
        }, "FLAC upgrades")
    await session.model.poll()
    await settled(downloads)
    #expect(fake.created.count == 3, "never more than three")

    let landed = try #require(fake.job(1))
    fake.put(listed(landed.id, release: landed.release.releaseID, .imported))
    library.upgraded(landed.release.releaseID)
    await session.model.poll()
    await eventually("a fourth queued") { fake.created.count == 4 }
    #expect(fake.created.last?.release == 3)
    await settled(downloads)
    let own = try LibraryIndex(at: session.setup.databaseURL).autoUpgradeJobs()
    #expect(own.map(\.jobID) == [2, 3, 4], "the landed one forgotten")

    downloads.autoUpgrade = false
    fake.put(listed(2, release: 2, .imported))
    await session.model.poll()
    await settled(downloads)
    #expect(fake.created.count == 4, "turned off, nothing more is queued")
    downloads.stop()
}

@MainActor
@Test func aJobThatFindsNothingIsCancelledAndWaitsADay() async throws {
    let fake = FakeService()
    let (downloads, session) = try await upgrading(
        fake, Library([candidate(1, plays: 9), candidate(2)]), inFlight: 1)
    downloads.autoUpgrade = true
    await eventually("queued") { fake.created.count == 1 }
    await settled(downloads)
    let start = Date()
    downloads.now = { start }
    fake.put(listed(1, release: 1, .notFound))
    await session.model.poll()
    await eventually("the next queued") { fake.created.count == 2 }
    #expect(fake.job(1)?.state == .cancelled)
    #expect(fake.created.last?.release == 2, "the first waits")
    let misses = try LibraryIndex(at: session.setup.databaseURL).upgradeMisses()
    #expect(misses[1]?.misses == 1)
    #expect(misses[1]?.retryAt == start.timeIntervalSince1970 + day)
    downloads.stop()
}

@MainActor
@Test func aCopyTaggedWithADiscrepancyIsRequeuedButNotAnUpgradeQueuedByHand() async throws {
    let discrepancy = DownloadJob.Tagging(status: .discrepancy, reasons: ["a bonus track"])
    let byHand = listed(1, release: 99, .staged) { $0.tagging = discrepancy }
    let fake = FakeService([byHand])
    let (downloads, session) = try await upgrading(fake, Library([candidate(1)]), inFlight: 1)
    downloads.autoUpgrade = true
    await eventually("queued") { fake.created.count == 1 }
    await settled(downloads)
    fake.put(listed(2, release: 1, .staged) { $0.tagging = discrepancy })
    await session.model.poll()
    await eventually("requeued") { fake.requeued == [2] }
    #expect(fake.job(2)?.state == .queued)
    #expect(fake.job(1)?.state == .staged, "Upgrades…'s job stays for the owner")
    await session.model.poll()
    await settled(downloads)
    #expect(fake.created.count == 1, "the requeued job still holds its slot")
    downloads.stop()
}

@MainActor
@Test func aLossyOriginFindingInItsOwnJobIsRequeued() async throws {
    let fake = FakeService()
    let (downloads, session) = try await upgrading(fake, Library([candidate(1)]), inFlight: 1)
    let lossy = StagedOrigin(
        path: "/s/job-1/01 First Song.flac",
        verdicts: [Verdict(kind: .lossyOrigin, text: "suspect lossy origin")], failure: nil)
    downloads.checkedPlan = { job, _, _ in
        ApprovalPlan(
            job: job, resuming: false, moves: job.files.map { ($0.name, "/l/A/\($0.name)") },
            movesProblem: nil, old: [], unmatched: [], upgradeProblem: nil, origins: [lossy],
            originsProblem: nil)
    }
    downloads.autoUpgrade = true
    await eventually("queued") { fake.created.count == 1 }
    await settled(downloads)
    fake.put(
        listed(1, release: 1, .staged) {
            $0.tagging = DownloadJob.Tagging(status: .clean, reasons: [])
        })
    downloads.autoApprove = true
    await session.model.poll()
    await eventually("requeued") { fake.requeued == [1] }
    await eventually("a new copy is looked at again") {
        session.model.leftForReview[1] == nil && !downloads.notClean.contains(1)
    }
    downloads.stop()
}
