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
