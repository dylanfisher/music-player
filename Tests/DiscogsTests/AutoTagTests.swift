import Foundation
import Testing

@testable import Discogs
@testable import Fixtures
@testable import Metadata
@testable import Recommender
@testable import Settings
@testable import TagWriter

// AutoTag on staged albums in a temporary staging folder, against a test catalog (StagedSetup).

private func reasons(_ run: AutoTagRun) -> [String] {
    switch run.verdict {
    case .clean: []
    case .discrepancy(let reasons), .error(let reasons): reasons
    }
}

@Test func anExactAlbumIsCleanWithEveryFieldReplaced() async throws {
    // The mapping fills the title only where empty; AutoTag replaces it all the same.
    var mapping = DiscogsPreset.oneToOne.mapping
    mapping[.album].mode = .fillEmpty
    let run = try await StagedSetup().run(exactStaging, mapping: mapping)
    #expect(run.verdict == .clean)
    #expect(run.edits.count == 3)
    #expect(run.edits.allSatisfy { $0.edit.values[.album] == "Made-Up Album" })
    #expect(run.staged.files.map(\.id).allSatisfy { $0 < 0 })
}

@Test func aWrongTitleIsADiscrepancyThatWritesNothing() async throws {
    var files = exactStaging
    files[1].title = "Something Else Entirely"
    let run = try await StagedSetup().run(files)
    #expect(
        run.verdict == .discrepancy(["track 2 is titled Something Else Entirely, not Second Song"]))
    #expect(run.edits.isEmpty)
}

@Test func aMissingTrackIsADiscrepancy() async throws {
    let run = try await StagedSetup().run(Array(exactStaging.prefix(2)))
    #expect(reasons(run).contains("2 files, release has 3"))
    #expect(reasons(run).contains("track 3 has no file"))
    #expect(run.edits.isEmpty)
}

@Test func aTrackFortySecondsOffIsADiscrepancy() async throws {
    var release = stagedSongs
    release[1].duration = "0:40"
    let run = try await StagedSetup(release: release).run(exactStaging)
    #expect(run.verdict == .discrepancy(["track 2 is 40 s off"]))
}

@Test func anExtraFileIsADiscrepancy() async throws {
    let files = exactStaging + [Staged(name: "04 Bonus Beat.flac", title: "Bonus Beat", number: 4)]
    let run = try await StagedSetup().run(files)
    #expect(reasons(run).contains("4 files, release has 3"))
    #expect(reasons(run).contains("04 Bonus Beat.flac fits no track"))
}

@Test func anUnreadableFileIsAnError() async throws {
    var files = exactStaging
    files[2].sample = .garbage
    let run = try await StagedSetup().run(files)
    guard case .error(let reasons) = run.verdict else {
        Issue.record("\(run.verdict)")
        return
    }
    #expect(reasons.count == 1)
    #expect(reasons.first?.contains("03 Third Song.flac") == true)
    #expect(run.match == nil)
}

@Test func aDSDFileCantBeWrittenSoItsADiscrepancy() async throws {
    let files = exactStaging.map { file in
        var dsd = file
        dsd.name = file.name.replacingOccurrences(of: ".flac", with: ".dsf")
        dsd.sample = .dsf
        dsd.title = nil
        dsd.number = nil
        return dsd
    }
    let run = try await StagedSetup().run(files)
    #expect(reasons(run).contains("01 First Song.dsf: Tags in DSD files can't be written yet"))
    #expect(run.edits.isEmpty)
}

@Test func untaggedTitlesAreFilledFromTheFileNames() async throws {
    let files = stagedSongs.enumerated().map { index, song in
        Staged(
            name: "0\(index + 1) - Made-Up Artist - \(song.title).flac", title: nil, number: nil,
            position: song.position)
    }
    let run = try await StagedSetup().run(files)
    #expect(run.verdict == .clean)
    #expect(run.staged.album.tracks.map(\.title) == stagedSongs.map(\.title))
}

@Test func aLossyM4AIsNotTheALACTheServiceTookItFor() async throws {
    let files = exactStaging.map { file in
        var m4a = file
        m4a.name = file.name.replacingOccurrences(of: ".flac", with: ".m4a")
        m4a.sample = .aac
        return m4a
    }
    let run = try await StagedSetup().run(files, format: .alac)
    #expect(reasons(run).contains("01 First Song.m4a is AAC, not ALAC"))
    #expect(run.edits.isEmpty)
}

@Test func aMappingThatDisagreesWithTheServicesIsADiscrepancy() async throws {
    var files = exactStaging
    files[0].position = "2"
    files[1].position = "1"
    let run = try await StagedSetup().run(files)
    #expect(
        run.verdict
            == .discrepancy([
                "01 First Song.flac is track 1, the service said 2",
                "02 Second Song.flac is track 2, the service said 1",
            ]))
}

@Test func aJobWhoseReleaseTheCatalogLacksIsAnErrorThoughAnotherMatches() async throws {
    // The files are tagged as the catalog's release 4242, which the matcher picks when 99
    // isn't there.
    let setup = try StagedSetup()
    let other = try await setup.run(exactStaging, namingTheRelease: true)
    #expect(other.verdict == .clean)
    try FileManager.default.removeItem(at: setup.root)
    let run = try await setup.run(exactStaging, releaseID: 99, namingTheRelease: true)
    #expect(
        run.verdict == .error([ReleaseSnapshot.Problem.notInCatalog(releaseID: 99).description]))
    #expect(run.edits.isEmpty)
    #expect(run.match == nil)
}

/// Grows each of `run`'s files by writing a long comment, as a tag write does when the padding
/// runs out.
private func grow(_ run: AutoTagRun, _ setup: StagedSetup) {
    var edit = TagEdit()
    edit.values[.comment] = String(repeating: "x", count: 100_000)
    let writer = TagWriter(
        journal: TagUndoJournal(
            dataDirectory: setup.dumps.directory.appendingPathComponent("grow", isDirectory: true))
    )
    #expect(writer.write(run.edits.map { ($0.path, edit) }).failures.isEmpty)
}

@Test func filesThatGrewInTheTagWriteReadWithTheirRecordedSizes() async throws {
    let setup = try StagedSetup()
    let first = try await setup.run(exactStaging)
    grow(first, setup)
    var job = try #require(setup.job)
    // The service's sizes are the ones before the write, so the files no longer match them.
    let refused = try await setup.autoTag()
    guard case .error(let reasons) = refused.verdict else {
        Issue.record("\(refused.verdict)")
        return
    }
    #expect(reasons.allSatisfy { $0.contains("the service staged") })
    #expect(reasons.count == 1)

    job.tagged = try job.sizesOnDisk(stagingRoot: setup.root.path)
    let again = try await Discogs.autoTag(
        job, stagingRoot: setup.root.path, catalogAt: setup.dumps.catalog, mapping: setup.mapping)
    #expect(again.staged.problems.isEmpty)
    #expect(again.verdict == .clean)
}

@Test func aFileOfNeitherSizeIsStillRefused() async throws {
    let setup = try StagedSetup()
    _ = try await setup.run(exactStaging)
    var job = try #require(setup.job)
    job.tagged = try job.sizesOnDisk(stagingRoot: setup.root.path)
    let path = setup.root.appendingPathComponent("job-7/02 Second Song.flac").path
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path, isDirectory: false))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("more".utf8))
    try handle.close()
    let staged = StagedAlbum(job, stagingRoot: setup.root.path)
    #expect(staged.problems.count == 1)
    #expect(staged.problems.first?.contains("02 Second Song.flac") == true)
}

@Test func theTaggersJobHoldsFilesToTheirSizesAfterEachOfItsWrites() async throws {
    let setup = try StagedSetup()
    let first = try await setup.run(exactStaging)
    let sizes = StagedSizes(try #require(setup.job), stagingRoot: setup.root.path)
    #expect(StagedAlbum(sizes.job, stagingRoot: setup.root.path).problems.isEmpty)

    grow(first, setup)
    #expect(StagedAlbum(sizes.job, stagingRoot: setup.root.path).problems.count == 1)
    try sizes.wrote()
    #expect(StagedAlbum(sizes.job, stagingRoot: setup.root.path).problems.isEmpty)
}
