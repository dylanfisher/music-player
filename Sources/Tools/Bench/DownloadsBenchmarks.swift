import Analysis
import Fixtures
import Foundation
import Library
import Recommender

/// The staged album Approve's row moves in: as many files as a fixture album holds most often.
private let stagedTrackCount = 12

/// Approve of one staged album, its parts timed: the sheet's moves, the lossy-origin check of
/// its first and last file, then the import run that reports, moves the files in and asks for
/// a rescan, as Downloads runs them (ADR 0147).
private struct ApproveRun {
    var destinationsSeconds: Double
    var originsSeconds: Double
    var importSeconds: Double
    var stagedMB: Double

    var seconds: Double { destinationsSeconds + originsSeconds + importSeconds }
}

/// Approves a staged album of `stagedTrackCount` fixture FLACs, its first and last five-minute
/// 24/96 files as the analysis rows' and the rest six seconds long, new to a library folder
/// that holds the fixture library's artist folders, all under a scratch folder on this Mac.
/// The service is a stand-in that accepts the job; nothing leaves the scratch folder.
private func approveRun() throws -> ApproveRun {
    let fixtures = try defaultPlaybackFixturesDirectory()
    let long = try analysisFixture(.hiRes, seconds: 300, in: fixtures)
    let short = try analysisFixture(.hiRes, in: fixtures)
    let artists = try FileManager.default.contentsOfDirectory(
        atPath: try defaultFixturesDirectory().path)
    return try withScratchDirectory("approve") { directory in
        let share = directory.appendingPathComponent("nas").path
        let staging = share + "/staging"
        let library = share + "/library folder"
        let job = "job-1"
        for artist in artists {
            try FileManager.default.createDirectory(
                atPath: library + "/" + artist, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            atPath: staging + "/" + job, withIntermediateDirectories: true)
        var listed: [ListedFile] = []
        var stagedBytes = 0
        for track in 1...stagedTrackCount {
            let name = "Track \(track).flac"
            let path = staging + "/" + job + "/" + name
            try writeTaggedFLAC(
                from: track == 1 || track == stagedTrackCount ? long : short,
                to: URL(fileURLWithPath: path, isDirectory: false), artist: "Staged Artist",
                album: "Staged Album", title: "Staged Track \(track)", trackNumber: track,
                trackTotal: stagedTrackCount)
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int
            stagedBytes += size
            listed.append(ListedFile(name: name, size: size, position: "\(track)"))
        }
        // As the service lists them.
        let files = try JSONDecoder().decode(
            [DownloadJob.File].self, from: try JSONEncoder().encode(listed))
        let databaseURL = libraryFileURL(in: directory)
        _ = try LibraryIndex(at: databaseURL)
        let move = LibraryFolderMove(stagingRoot: staging, libraryFolder: library, shareRoot: share)
        var destinations: [String] = []
        let destinationsSeconds = try seconds {
            destinations = try move.destinations(
                folder: job, files: files.map { ($0.name, $0.sizeBytes) })
        }
        let paths = files.map { staging + "/" + job + "/" + $0.name }
        var origins: [StagedOrigin] = []
        let originsSeconds = try seconds { origins = try waited { try await stagedOrigins(paths) } }
        guard origins.count == 2, origins.allSatisfy({ !$0.blocks }) else {
            throw BenchError.expected("two staged files analyzed, both clean: \(origins)")
        }
        let approved = ApprovedImport(
            jobID: 1, releaseID: 1, state: .staged, folder: job, files: files, upgrade: nil)
        var outcome: ImportOutcome?
        let importSeconds = try seconds {
            outcome = try waited {
                let run = ImportRun(
                    index: try LibraryIndex(at: databaseURL), move: move,
                    trash: { _ in "the bench trashes nothing" },
                    carry: { _ in throw BenchError.expected("no stats to carry for a new album") },
                    rescan: { _ in }, deliver: { nil })
                return await run.run(approved)
            }
        }
        guard outcome == .imported(destinations) else {
            throw BenchError.expected(
                "the album imported where the sheet said: \(String(describing: outcome))")
        }
        return ApproveRun(
            destinationsSeconds: destinationsSeconds, originsSeconds: originsSeconds,
            importSeconds: importSeconds, stagedMB: Double(stagedBytes) / 1e6)
    }
}

/// A staged file as the service lists it.
private struct ListedFile: Encodable {
    var name: String
    var size: Int
    var position: String
}

let downloadsBenchmarks = [
    Benchmark(
        name:
            "downloads: Approve a staged \(stagedTrackCount)-file album, from its moves and"
            + " lossy-origin check to the files in the library, local",
        budget: Budget(appleSilicon: 5, oldMac: 30, unit: .seconds)
    ) {
        let run = try approveRun()
        return Measured(
            value: run.seconds,
            notes: [
                String(
                    format: "the sheet's moves %.0f ms, the lossy-origin check %.2f s, the import"
                        + " %.0f ms; %.0f MB staged",
                    run.destinationsSeconds * 1000, run.originsSeconds, run.importSeconds * 1000,
                    run.stagedMB)
            ])
    }
]
