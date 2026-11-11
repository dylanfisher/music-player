import Foundation
import Testing

@testable import Library
@testable import Metadata

private let day = 86_400.0

@Test func aMissWaitsOneSevenThenThirtyDaysAndTheFourthSetsItAside() throws {
    let index = try craftedIndex([])
    let job = AutoUpgradeJob(epoch: "e1", jobID: 3, releaseID: 4242)
    let start = 1_800_000_000.0
    var waits: [Double?] = []
    for miss in 0..<4 {
        try index.recordAutoUpgradeJob(job)
        let at = start + Double(miss) * 100 * day
        let recorded = try index.recordUpgradeMiss(job, at: at)
        #expect(recorded.misses == miss + 1)
        waits.append(recorded.retryAt.map { ($0 - at) / day })
        #expect(try index.autoUpgradeJobs().isEmpty, "the job is forgotten with its miss")
    }
    #expect(waits == [1, 7, 30, nil])
    #expect(try index.upgradeMisses()[4242]?.isSetAside == true)
    try index.clearUpgradeMisses(releases: [4242])
    #expect(try index.upgradeMisses().isEmpty, "Queue Again clears the count")
}

@Test func theJobsItQueuedAreKeptByEpochAndId() throws {
    let index = try craftedIndex([])
    let first = AutoUpgradeJob(epoch: "e1", jobID: 3, releaseID: 1)
    let other = AutoUpgradeJob(epoch: "e2", jobID: 3, releaseID: 2)
    try index.recordAutoUpgradeJob(first)
    try index.recordAutoUpgradeJob(other)
    #expect(try index.autoUpgradeJobs() == [first, other])
    try index.forgetAutoUpgradeJob(first)
    #expect(try index.autoUpgradeJobs() == [other])
}

@Test func neverUpgradeTogglesTheSelectedTracksReleases() throws {
    let root = "/Volumes/music/library"
    let tracks: [(name: String, release: String?)] = [
        ("1", "42"), ("2", "42"), ("3", "43"), ("4", nil),
    ]
    let files = tracks.map { name, release in
        Crafted(
            path: "\(root)/\(name).mp3", title: name, album: "Album \(release ?? "none")",
            custom: release.map { [DiscogsKey.releaseID: $0] } ?? [:]
        ).scanned
    }
    let index = try craftedIndex(files)
    let ids = try index.trackIDs(atPaths: files.map(\.path)).map { try #require($0) }
    #expect(try index.toggleNeverUpgrade(trackIDs: [ids[3]]) == nil, "no release id")
    #expect(try index.toggleNeverUpgrade(trackIDs: [ids[0]]) == true)
    #expect(try index.neverUpgradeReleases() == [42])
    #expect(try index.toggleNeverUpgrade(trackIDs: [ids[1], ids[2]]) == true, "43 wasn't marked")
    #expect(try index.neverUpgradeReleases() == [42, 43])
    #expect(try index.toggleNeverUpgrade(trackIDs: [ids[0], ids[2]]) == false)
    #expect(try index.neverUpgradeReleases().isEmpty)
}
