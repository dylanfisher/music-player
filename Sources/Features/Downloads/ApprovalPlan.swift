import Analysis
import Discogs
import Foundation
import Library
import Metadata
import Recommender

/// Where an import reads and writes on this Mac, found when it's needed: the staging folder,
/// the library folder, and where their share is mounted, which the ledger and an upgrade's
/// old files are relative to.
package struct ImportPlaces: Equatable, Sendable {
    package var stagingRoot: String
    package var libraryFolder: String
    package var shareRoot: String

    package init(stagingRoot: String, libraryFolder: String, shareRoot: String) {
        self.stagingRoot = stagingRoot
        self.libraryFolder = libraryFolder
        self.shareRoot = shareRoot
    }

    var move: LibraryFolderMove {
        LibraryFolderMove(
            stagingRoot: stagingRoot, libraryFolder: libraryFolder, shareRoot: shareRoot)
    }
}

/// What Approve does to one job, as its sheet lists it (ADR 0147): each staged file and where
/// it goes; for an upgrade, the old files it deletes and those with no new file, which the
/// owner ticks to lose; and the lossy-origin check of the staged files. Worked out before
/// anything moves, and the sheet's Approve stays off while `blockers` lists anything.
struct ApprovalPlan: Sendable {
    var job: DownloadJob
    /// The job is approved or importing already: Resume Here runs the steps left, and the
    /// staged files may be in the library by now.
    var resuming: Bool
    /// Each staged file's name and where it goes in the library.
    var moves: [(name: String, destination: String)]
    /// Why the moves couldn't be worked out: a file already at a destination, the folders on
    /// two volumes. Nil when they were.
    var movesProblem: String?
    /// An upgrade's old files, each with its release position.
    var old: [UpgradeOldFile]
    /// The old files with no new file at their position.
    var unmatched: [UpgradeOldFile]
    /// Why an upgrade's old files couldn't be found; nil when they were, or it isn't one.
    var upgradeProblem: String?
    /// The staged files analyzed, each with what it shows.
    var origins: [StagedOrigin]
    var originsProblem: String?

    var isUpgrade: Bool { job.upgrade != nil }

    /// Whether the lossy-origin check asks the owner to acknowledge what it found.
    var originsBlock: Bool { originsProblem != nil || origins.contains(where: \.blocks) }

    /// Why Approve can't go ahead yet, given the old files `ticked` to lose and whether the
    /// origins' findings are acknowledged; empty when it can.
    func blockers(ticked: Set<String>, acknowledgedOrigins: Bool) -> [String] {
        var found: [String] = []
        if !resuming, let movesProblem { found.append(movesProblem) }
        if !resuming, let upgradeProblem { found.append(upgradeProblem) }
        let unticked = unmatched.filter { !ticked.contains($0.sharePath) }
        if !unticked.isEmpty {
            found.append(
                "Tick the \(unticked.count) old file\(unticked.count == 1 ? "" : "s") with no new"
                    + " one, to lose \(unticked.count == 1 ? "it" : "them").")
        }
        if originsBlock && !acknowledgedOrigins {
            found.append("Acknowledge what the lossy-origin check found.")
        }
        return found
    }

    /// The import the owner approved, with the old files `ticked`; nil until `blockers` is
    /// empty, or for a job the service listed with no staged folder.
    func approved(ticked: Set<String>, acknowledgedOrigins: Bool) -> ApprovedImport? {
        guard blockers(ticked: ticked, acknowledgedOrigins: acknowledgedOrigins).isEmpty,
            let folder = job.stagedPath
        else { return nil }
        return ApprovedImport(
            jobID: job.id, releaseID: job.release.releaseID, state: job.state, folder: folder,
            files: job.files,
            upgrade: isUpgrade
                ? ApprovedImport.Upgrade(
                    old: old,
                    acknowledged: ticked.intersection(unmatched.map(\.sharePath)))
                : nil)
    }

    /// The plan for `job`, read from the staged files, the index at `databaseURL` and the
    /// catalog at `catalog` (nil on a Mac without one). Reads off the main thread.
    static func build(
        _ job: DownloadJob, places: ImportPlaces, databaseURL: URL, catalog: URL?
    ) async -> ApprovalPlan {
        let resuming = job.state == .approved || job.state == .importing
        var plan = ApprovalPlan(
            job: job, resuming: resuming, moves: [], movesProblem: nil, old: [], unmatched: [],
            upgradeProblem: nil, origins: [], originsProblem: nil)
        guard let folder = job.stagedPath else {
            plan.movesProblem = "the service listed the job with no staged folder"
            return plan
        }
        if !resuming {
            let found = await blockingFileWork {
                Result { () throws -> [String] in
                    // The files are held to their sizes since the player's tag write.
                    let sized = try LibraryIndex(at: databaseURL).sizedAfterTagging(
                        job.files, job: job.id, folder: folder)
                    return try places.move.destinations(
                        folder: folder, files: sized.map { ($0.name, $0.sizeBytes) })
                }
            }
            switch found {
            case .success(let destinations):
                plan.moves = zip(job.files.map(\.name), destinations).map { ($0, $1) }
            case .failure(let error):
                plan.movesProblem = "\(error)"
            }
            let paths = job.files.map { places.stagingRoot + "/" + folder + "/" + $0.name }
            do {
                plan.origins = try await stagedOrigins(paths)
            } catch {
                plan.originsProblem = "\(error)"
            }
        }
        if let upgrade = job.upgrade {
            do {
                let old = try await positioned(
                    upgrade.oldPaths, release: job.release.releaseID, places: places,
                    databaseURL: databaseURL, catalog: catalog)
                plan.old = old
                plan.unmatched =
                    UpgradeMapping(old: old, new: job.files.map { ($0.name, $0.position) })
                    .unmatched
            } catch {
                plan.upgradeProblem = "The old album's files: \(error)"
            }
        }
        return plan
    }

    /// The upgrade's old files `sharePaths`, as the index has them, each placed on the release
    /// by the matcher, as the new files are.
    private static func positioned(
        _ sharePaths: [String], release: Int, places: ImportPlaces, databaseURL: URL,
        catalog: URL?
    ) async throws -> [UpgradeOldFile] {
        guard let catalog else {
            throw ReleaseSnapshot.Problem.notInCatalog(releaseID: release)
        }
        let read = await blockingFileWork {
            Result { () throws -> ([UpgradeOldFile], DiscogsAlbum, [String: Int64]) in
                let index = try LibraryIndex(at: databaseURL)
                let old = try index.upgradeOldFiles(
                    sharePaths, release: release, shareRoot: places.shareRoot)
                var ids: [String: Int64] = [:]
                var albumIDs: Set<Int64> = []
                for file in old {
                    guard let track = try index.track(path: file.path) else {
                        throw UpgradeRefusal.notInLibrary(file.path)
                    }
                    ids[file.path] = track.id
                    if let album = track.albumID { albumIDs.insert(album) }
                }
                guard albumIDs.count == 1, let albumID = albumIDs.first,
                    let album = try index.discogsAlbums().first(where: { $0.id == albumID })
                else { throw OldFilesNotOneAlbum(albums: albumIDs.count) }
                return (old, album, ids)
            }
        }
        let (old, album, ids) = try read.get()
        let positions = try await upgradePositions(of: album, release: release, catalogAt: catalog)
        return old.map { file in
            var file = file
            file.position = ids[file.path].flatMap { positions[$0] }
            return file
        }
    }
}

/// An upgrade's old files aren't the tracks of one library album.
struct OldFilesNotOneAlbum: Error, CustomStringConvertible {
    var albums: Int

    var description: String {
        "the old files are in \(albums) albums in the library, not one; tag them as one first"
    }
}
