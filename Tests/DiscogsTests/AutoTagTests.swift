import Foundation
import Testing

@testable import Discogs
@testable import Fixtures
@testable import Metadata
@testable import Recommender
@testable import Settings
@testable import TagWriter

// AutoTag on staged albums made of generated fixtures in a temporary staging folder, against a
// test catalog. Nothing here writes a staged file but the setup's own tags.

private let releaseID = 4242

/// The release's dump record: three tracks of `seconds` each, or as given.
private func releaseXML(_ tracks: [(position: String, title: String, duration: String)]) -> String {
    let tracklist = tracks.map {
        "<track><position>\($0.position)</position><title>\($0.title)</title><duration>\($0.duration)</duration></track>"
    }.joined()
    return
        #"<release id="\#(releaseID)"><artists><artist><id>1</id><name>Made-Up Artist</name></artist></artists><title>Made-Up Album</title><labels><label name="Svek" catno="SK 032" id="5"/></labels><formats><format name="File" qty="1"><descriptions><description>FLAC</description></descriptions></format></formats><released>1999-03-00</released><tracklist>\#(tracklist)</tracklist></release>"#
        + "\n"
}

private let songs = [
    (position: "1", title: "First Song", duration: "0:00"),
    (position: "2", title: "Second Song", duration: "0:00"),
    (position: "3", title: "Third Song", duration: "0:00"),
]

/// A fixture file of one kind, to copy as each staged file.
private enum Sample {
    case flac, aac, alac, dsf, garbage

    func matches(_ file: FixtureFile) -> Bool {
        switch self {
        case .garbage: return file.malformation == .garbage
        default: guard file.malformation == nil, file.tags != nil else { return false }
        }
        switch self {
        case .flac: return file.audio?.codec == .flac
        case .aac: return file.container == .mp4 && file.audio?.codec == .aac
        case .alac: return file.container == .mp4 && file.audio?.codec == .alac
        case .dsf: return file.container == .dsf
        case .garbage: return true
        }
    }
}

/// One staged file: its name in the job's folder, the fixture it copies, the title and track
/// number to tag it with (nil removes the tag), and the position the service reported.
private struct Staged {
    var name: String
    var sample = Sample.flac
    var title: String?
    var number: Int?
    var position: String?
}

/// The three songs, staged in order as FLAC with their titles, as the service matched them.
private let exact = songs.enumerated().map { index, song in
    Staged(
        name: "0\(index + 1) \(song.title).flac", title: song.title, number: index + 1,
        position: song.position)
}

/// A staging folder and a catalog of the release, for one test.
private final class Setup {
    let dumps: DumpFolder
    let root: URL

    init(release tracks: [(position: String, title: String, duration: String)] = songs) throws {
        dumps = try DumpFolder()
        root = dumps.directory.appendingPathComponent("staging", isDirectory: true)
        try dumps.write("20261101", releases: releaseXML(tracks))
        try dumps.importCatalog()
    }

    /// Copies `files` into `job-7` and tags them, then runs AutoTag on them for `format`.
    func run(
        _ files: [Staged], format: DownloadJob.Candidate.Format = .flac,
        mapping: DiscogsMapping = DiscogsPreset.oneToOne.mapping
    ) async throws -> AutoTagRun {
        let (fixtures, manifest) = try fixtureLibrary.get()
        let folder = root.appendingPathComponent("job-7", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var edits: [(path: String, edit: TagEdit)] = []
        var jobFiles: [DownloadJob.File] = []
        for file in files {
            let source = try #require(manifest.files.first(where: file.sample.matches))
            let copy = folder.appendingPathComponent(file.name, isDirectory: false)
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(source.path, isDirectory: false), to: copy)
            var edit = TagEdit()
            edit.values[.title] = file.title ?? ""
            edit.values[.trackNumber] = file.number.map(String.init) ?? ""
            edit.values[.discNumber] = ""
            if file.sample != .garbage && file.sample != .dsf { edits.append((copy.path, edit)) }
            let size = try #require(
                try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int)
            jobFiles.append(
                DownloadJob.File(name: file.name, sizeBytes: size, position: file.position))
        }
        let writer = TagWriter(
            journal: TagUndoJournal(
                dataDirectory: dumps.directory.appendingPathComponent("setup", isDirectory: true)))
        let report = writer.write(edits)
        try #require(report.failures == [])
        // The writes above change sizes, which the service's list has to match.
        for index in jobFiles.indices {
            let path = folder.appendingPathComponent(jobFiles[index].name).path
            jobFiles[index].sizeBytes = try #require(
                try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        }
        let job = StagedJob(
            releaseID: releaseID, artist: "Made-Up Artist", folder: "job-7", format: format,
            files: jobFiles)
        return try await autoTag(
            job, stagingRoot: root.path, catalogAt: dumps.catalog, mapping: mapping)
    }
}

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
    let run = try await Setup().run(exact, mapping: mapping)
    #expect(run.verdict == .clean)
    #expect(run.edits.count == 3)
    #expect(run.edits.allSatisfy { $0.edit.values[.album] == "Made-Up Album" })
    #expect(run.staged.files.map(\.id).allSatisfy { $0 < 0 })
}

@Test func aWrongTitleIsADiscrepancyThatWritesNothing() async throws {
    var files = exact
    files[1].title = "Something Else Entirely"
    let run = try await Setup().run(files)
    #expect(
        run.verdict == .discrepancy(["track 2 is titled Something Else Entirely, not Second Song"]))
    #expect(run.edits.isEmpty)
}

@Test func aMissingTrackIsADiscrepancy() async throws {
    let run = try await Setup().run(Array(exact.prefix(2)))
    #expect(reasons(run).contains("2 files, release has 3"))
    #expect(reasons(run).contains("track 3 has no file"))
    #expect(run.edits.isEmpty)
}

@Test func aTrackFortySecondsOffIsADiscrepancy() async throws {
    var release = songs
    release[1].duration = "0:40"
    let run = try await Setup(release: release).run(exact)
    #expect(run.verdict == .discrepancy(["track 2 is 40 s off"]))
}

@Test func anExtraFileIsADiscrepancy() async throws {
    let files = exact + [Staged(name: "04 Bonus Beat.flac", title: "Bonus Beat", number: 4)]
    let run = try await Setup().run(files)
    #expect(reasons(run).contains("4 files, release has 3"))
    #expect(reasons(run).contains("04 Bonus Beat.flac fits no track"))
}

@Test func anUnreadableFileIsAnError() async throws {
    var files = exact
    files[2].sample = .garbage
    let run = try await Setup().run(files)
    guard case .error(let reasons) = run.verdict else {
        Issue.record("\(run.verdict)")
        return
    }
    #expect(reasons.count == 1)
    #expect(reasons.first?.contains("03 Third Song.flac") == true)
    #expect(run.match == nil)
}

@Test func aDSDFileCantBeWrittenSoItsADiscrepancy() async throws {
    let files = exact.map { file in
        var dsd = file
        dsd.name = file.name.replacingOccurrences(of: ".flac", with: ".dsf")
        dsd.sample = .dsf
        dsd.title = nil
        dsd.number = nil
        return dsd
    }
    let run = try await Setup().run(files)
    #expect(reasons(run).contains("01 First Song.dsf: Tags in DSD files can't be written yet"))
    #expect(run.edits.isEmpty)
}

@Test func untaggedTitlesAreFilledFromTheFileNames() async throws {
    let files = songs.enumerated().map { index, song in
        Staged(
            name: "0\(index + 1) - Made-Up Artist - \(song.title).flac", title: nil, number: nil,
            position: song.position)
    }
    let run = try await Setup().run(files)
    #expect(run.verdict == .clean)
    #expect(run.staged.album.tracks.map(\.title) == songs.map(\.title))
}

@Test func aLossyM4AIsNotTheALACTheServiceTookItFor() async throws {
    let files = exact.map { file in
        var m4a = file
        m4a.name = file.name.replacingOccurrences(of: ".flac", with: ".m4a")
        m4a.sample = .aac
        return m4a
    }
    let run = try await Setup().run(files, format: .alac)
    #expect(reasons(run).contains("01 First Song.m4a is AAC, not ALAC"))
    #expect(run.edits.isEmpty)
}

@Test func aMappingThatDisagreesWithTheServicesIsADiscrepancy() async throws {
    var files = exact
    files[0].position = "2"
    files[1].position = "1"
    let run = try await Setup().run(files)
    #expect(
        run.verdict
            == .discrepancy([
                "01 First Song.flac is track 1, the service said 2",
                "02 Second Song.flac is track 2, the service said 1",
            ]))
}
