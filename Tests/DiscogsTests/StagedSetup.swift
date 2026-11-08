import Foundation
import Testing

@testable import Discogs
@testable import Fixtures
@testable import Recommender
@testable import Settings
@testable import TagWriter

// A staging folder of generated fixtures and a test catalog of their release, for AutoTag's and
// StagedWriter's tests. Only copies in a temporary folder are written.

private let stagedReleaseID = 4242

/// The release's dump record, with `tracks`.
private func releaseXML(_ tracks: [(position: String, title: String, duration: String)]) -> String {
    let tracklist = tracks.map {
        "<track><position>\($0.position)</position><title>\($0.title)</title><duration>\($0.duration)</duration></track>"
    }.joined()
    return
        #"<release id="\#(stagedReleaseID)"><artists><artist><id>1</id><name>Made-Up Artist</name></artist></artists><title>Made-Up Album</title><labels><label name="Svek" catno="SK 032" id="5"/></labels><formats><format name="File" qty="1"><descriptions><description>FLAC</description></descriptions></format></formats><released>1999-03-00</released><tracklist>\#(tracklist)</tracklist></release>"#
        + "\n"
}

let stagedSongs = [
    (position: "1", title: "First Song", duration: "0:00"),
    (position: "2", title: "Second Song", duration: "0:00"),
    (position: "3", title: "Third Song", duration: "0:00"),
]

/// A fixture file of one kind, to copy as each staged file.
enum Sample {
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
struct Staged {
    var name: String
    var sample = Sample.flac
    var title: String?
    var number: Int?
    var position: String?
}

/// The three songs, staged in order as FLAC with their titles, as the service matched them.
let exactStaging = stagedSongs.enumerated().map { index, song in
    Staged(
        name: "0\(index + 1) \(song.title).flac", title: song.title, number: index + 1,
        position: song.position)
}

/// A staging folder and a catalog of the release, for one test.
final class StagedSetup {
    let dumps: DumpFolder
    /// The staging folder.
    let root: URL
    /// A library folder beside it, which only `libraryFile` puts a file in.
    var library: URL { dumps.directory.appendingPathComponent("library", isDirectory: true) }
    /// The staged writer's data folder, apart from the main journal's.
    var stagedWriter: StagedWriter {
        StagedWriter(
            stagingRoot: root.path,
            dataDirectory: dumps.directory.appendingPathComponent("data", isDirectory: true))
    }
    /// The last job `run` staged, and the mapping it ran with.
    private(set) var job: StagedJob?
    private(set) var mapping = DiscogsPreset.oneToOne.mapping

    init(release tracks: [(position: String, title: String, duration: String)] = stagedSongs) throws
    {
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
        job = StagedJob(
            releaseID: stagedReleaseID, artist: "Made-Up Artist", folder: "job-7", format: format,
            files: jobFiles)
        self.mapping = mapping
        return try await autoTag()
    }

    /// AutoTag on the job `run` staged, as it is now.
    func autoTag() async throws -> AutoTagRun {
        try await Discogs.autoTag(
            try #require(job), stagingRoot: root.path, catalogAt: dumps.catalog,
            mapping: mapping)
    }

    /// A FLAC fixture copied into the library folder: a file outside staging.
    func libraryFile() throws -> String {
        let (fixtures, manifest) = try fixtureLibrary.get()
        let source = try #require(manifest.files.first(where: Sample.flac.matches))
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let copy = library.appendingPathComponent("01 Library Song.flac", isDirectory: false)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent(source.path, isDirectory: false), to: copy)
        return copy.path
    }
}
