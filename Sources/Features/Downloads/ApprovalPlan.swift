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
    /// A library album a job queued as a new album replaces (ADR 0169).
    struct Replaced: Equatable, Sendable {
        var artist: String?
        var title: String
        /// Found by its album artist and title, not its tracks' release id.
        var byName: Bool
        var files: Int
        /// Its quality, from the index; nil when it isn't known.
        var quality: AudioQuality? = nil
    }

    /// The moves for Keep Both: the job imported as a new album beside the one it replaces.
    struct KeepBoth: Sendable {
        var moves: [(name: String, destination: String)]
        var problem: String?
    }

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
    /// The job was queued as a new album, but one library album is its release's, by its
    /// tracks' release id or by its artist and title, so Approve replaces that album as an
    /// upgrade does, unless the owner keeps both.
    var replaced: Replaced?
    var keepBoth: KeepBoth?
    /// Why a job queued as a new album replaces none, though the library has its release.
    var notReplaced: String?
    /// The library folder the moves go into, which the sheet shows them relative to.
    var libraryFolder = ""
    /// The lossy-origin check is still reading the staged files.
    var checking = false

    var isUpgrade: Bool { job.upgrade != nil || replaced != nil }

    /// The staged files' quality: the service's candidate, held to what the lossy-origin check
    /// read of them; nil when it isn't known.
    var stagedQuality: AudioQuality? {
        AudioQuality.staged(job.candidate, measured: origins.compactMap(\.measures))
    }

    /// Whether the lossy-origin check asks the owner to acknowledge what it found.
    var originsBlock: Bool { originsProblem != nil || origins.contains(where: \.blocks) }

    /// Why Approve can't go ahead yet, given the old files `ticked` to lose, whether the
    /// origins' findings are acknowledged, and Keep Both; empty when it can.
    func blockers(ticked: Set<String>, acknowledgedOrigins: Bool, keepingBoth: Bool = false)
        -> [String]
    {
        let keepingBoth = keepingBoth && keepBoth != nil
        var found: [String] = []
        let movesProblem = keepingBoth ? keepBoth?.problem : movesProblem
        // A resume goes on whatever the moves found, but not from a folder it can't name.
        if !resuming || job.stagedFiles == nil, let movesProblem { found.append(movesProblem) }
        if !keepingBoth {
            if !resuming, let upgradeProblem { found.append(upgradeProblem) }
            let unticked = unmatched.filter { !ticked.contains($0.sharePath) }
            if !unticked.isEmpty {
                found.append(
                    "Tick the \(unticked.count) old file\(unticked.count == 1 ? "" : "s") with"
                        + " no new one, to lose \(unticked.count == 1 ? "it" : "them").")
            }
        }
        if checking {
            found.append(ApproveSheet.checkingNote)
        } else if originsBlock && !acknowledgedOrigins {
            found.append("Acknowledge what the lossy-origin check found.")
        }
        return found
    }

    /// The import the owner approved, with the old files `ticked`, or as a new album when
    /// `keepingBoth`; nil until `blockers` is empty, or for a job the service listed with no
    /// staged folder, or with a folder or a file outside the staging folder.
    func approved(ticked: Set<String>, acknowledgedOrigins: Bool, keepingBoth: Bool = false)
        -> ApprovedImport?
    {
        guard
            blockers(
                ticked: ticked, acknowledgedOrigins: acknowledgedOrigins, keepingBoth: keepingBoth
            ).isEmpty,
            let folder = job.stagedFolder, let files = job.stagedFiles
        else { return nil }
        return ApprovedImport(
            jobID: job.id, releaseID: job.release.releaseID, state: job.state, folder: folder,
            files: files,
            upgrade: isUpgrade && !(keepingBoth && keepBoth != nil)
                ? ApprovedImport.Upgrade(
                    old: old,
                    acknowledged: ticked.intersection(unmatched.map(\.sharePath)))
                : nil)
    }

    /// What Approve Safe Matches Automatically makes of a plan (ADR 0193).
    enum Unasked: Sendable {
        case approved(ApprovedImport)
        /// Left for the owner to review, saying why.
        case left(String)
        /// Left, saying why, with a lossy-origin finding among the reasons: a copy that isn't
        /// what it claims, which Upgrade to FLAC Automatically throws away when it's its own
        /// (ADR 0200).
        case notClean(String)
    }

    /// The import Approve makes with nothing ticked, acknowledged or kept, when the plan leaves
    /// the owner nothing to judge: a staged job's plan, checked, with no blockers that way,
    /// which says nothing of albums it can't replace. A library album it wasn't queued to
    /// upgrade it replaces, as Approve does with Keep Both off, only when it was found by its
    /// release id and the staged files are clearly higher quality (ADR 0195). Holding the job
    /// to its clean tagging is the caller's part.
    var unasked: Unasked {
        if resuming { return .left("the import has started already") }
        if checking { return .left(ApproveSheet.checkingNote) }
        if let replaced, let why = Self.notReplacedUnasked(replaced, by: stagedQuality) {
            return .left(why)
        }
        if let notReplaced { return .left(notReplaced) }
        let blockers = blockers(ticked: [], acknowledgedOrigins: false)
        if !blockers.isEmpty {
            let why = blockers.joined(separator: " ")
            // A finding, not a file the check couldn't read.
            return origins.contains { !$0.verdicts.isEmpty } ? .notClean(why) : .left(why)
        }
        guard let approved = approved(ticked: [], acknowledgedOrigins: false) else {
            return .left("the service listed the job with no staged folder")
        }
        return .approved(approved)
    }

    /// Why a job isn't approved unasked to replace `replaced`, which it wasn't queued to
    /// upgrade, with staged files of quality `staged`; nil when it may be.
    private static func notReplacedUnasked(_ replaced: Replaced, by staged: AudioQuality?)
        -> String?
    {
        if replaced.byName {
            return "it replaces the library album with its artist and title, which isn't tagged"
                + " with its release, and Approve asks whether to keep both"
        }
        guard let old = replaced.quality, let new = staged else {
            let old = replaced.quality.map(\.description) ?? "unknown quality"
            let new = staged.map(\.description) ?? "files of unknown quality"
            return "it replaces a library album of \(old) with \(new), which can't be compared"
        }
        guard new.isClearlyHigher(than: old) else {
            return "it isn't higher quality than the library's \(old) (\(new) isn't better)"
        }
        return nil
    }

    /// What the index says of the job: the album it replaces and where its files go.
    private struct Found: Sendable {
        var old: [String]?
        var replaced: (album: DiscogsAlbum, byName: Bool, quality: AudioQuality?)?
        var notReplaced: String?
        var moves: Result<[String], any Error>
        var keepBoth: Result<[String], any Error>?
    }

    /// The plan for `job`, read from the index at `databaseURL` and the catalog at `catalog`
    /// (nil on a Mac without one), without the lossy-origin check, which `checked(places:)`
    /// runs after; `checking` says it's to come. Reads off the main thread.
    static func build(
        _ job: DownloadJob, places: ImportPlaces, databaseURL: URL, catalog: URL?
    ) async -> ApprovalPlan {
        let resuming = job.state == .approved || job.state == .importing
        var plan = ApprovalPlan(
            job: job, resuming: resuming, moves: [], movesProblem: nil, old: [], unmatched: [],
            upgradeProblem: nil, origins: [], originsProblem: nil,
            libraryFolder: places.libraryFolder)
        guard let folder = job.stagedFolder, let files = job.stagedFiles else {
            plan.movesProblem =
                job.stagedProblem ?? "the service listed the job with no staged folder"
            return plan
        }
        var oldPaths = job.upgrade?.oldPaths
        if !resuming {
            let found = await blockingFileWork {
                Result { () throws -> Found in
                    try find(job, folder, files, places, databaseURL)
                }
            }
            switch found {
            case .success(let found):
                let names = files.map(\.name)
                switch found.moves {
                case .success(let destinations):
                    plan.moves = zip(names, destinations).map { ($0, $1) }
                case .failure(let error): plan.movesProblem = "\(error)"
                }
                if let replaced = found.replaced, let old = found.old {
                    plan.replaced = Replaced(
                        artist: replaced.album.artist, title: replaced.album.title,
                        byName: replaced.byName, files: old.count, quality: replaced.quality)
                    switch found.keepBoth {
                    case .success(let destinations):
                        plan.keepBoth = KeepBoth(
                            moves: zip(names, destinations).map { ($0, $1) }, problem: nil)
                    case .failure(let error):
                        plan.keepBoth = KeepBoth(moves: [], problem: "\(error)")
                    case nil: break
                    }
                }
                plan.notReplaced = found.notReplaced
                oldPaths = found.old
            case .failure(let error):
                plan.movesProblem = "\(error)"
            }
            plan.checking = true
        }
        if let oldPaths {
            do {
                let old = try await positioned(
                    oldPaths, release: job.release.releaseID,
                    heldToRelease: job.upgrade != nil, places: places,
                    databaseURL: databaseURL, catalog: catalog)
                plan.old = old
                let mapping = UpgradeMapping(
                    old: old, new: files.map { ($0.name, $0.position) })
                plan.unmatched = mapping.unmatched
                if !plan.moves.isEmpty {
                    do {
                        _ = try mapping.replacedInPlace(
                            old,
                            destinations: Dictionary(
                                plan.moves.map { ($0.name, $0.destination) },
                                uniquingKeysWith: { one, _ in one }))
                    } catch {
                        plan.movesProblem = "\(error)"
                    }
                }
            } catch {
                plan.upgradeProblem = "The old album's files: \(error)"
            }
        }
        return plan
    }

    /// The plan with the lossy-origin check of its staged files, under the staging folder of
    /// `places`. Throws only when cancelled.
    func checked(places: ImportPlaces) async throws -> ApprovalPlan {
        var plan = self
        plan.checking = false
        guard let folder = job.stagedFolder, let files = job.stagedFiles else { return plan }
        let paths = files.map { places.stagingRoot + "/" + folder + "/" + $0.name }
        do {
            plan.origins = try await stagedOrigins(paths)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            plan.originsProblem = "\(error)"
        }
        return plan
    }

    /// For a job queued as a new album, the library album of its release, when there's one,
    /// and where its staged `files` go: replacing that album's, and for Keep Both beside them.
    private static func find(
        _ job: DownloadJob, _ folder: String, _ files: [DownloadJob.File],
        _ places: ImportPlaces, _ databaseURL: URL
    ) throws -> Found {
        let index = try LibraryIndex(at: databaseURL)
        // The files are held to their sizes since the player's tag write.
        let files = try index.sizedAfterTagging(files, job: job.id, folder: folder)
            .map { ($0.name, $0.sizeBytes) }
        var found = Found(old: job.upgrade?.oldPaths, moves: .success([]))
        if job.upgrade == nil {
            let release = job.release
            switch libraryAlbum(
                replacedBy: release.releaseID, artist: release.artist, title: release.title,
                among: try index.discogsAlbums())
            {
            case .none: break
            case .several(let count, let byName):
                found.notReplaced =
                    "\(count) albums in the library "
                    + (byName ? "have this artist and title" : "are tagged with this release")
                    + ", so it's imported as a new album beside them."
            case .album(let album, let byName):
                if let paths = try index.albumFiles(album.id, shareRoot: places.shareRoot) {
                    found.old = paths
                    found.replaced = (album, byName, try index.albumQuality(album.id))
                } else {
                    found.notReplaced =
                        "The library's \(album.title) isn't all on the share the staging folder"
                        + " is on, so it's imported as a new album beside it."
                }
            }
        }
        found.moves = Result {
            try places.move.destinations(
                folder: folder, files: files,
                replacing: places.move.libraryPaths(found.old ?? []))
        }
        if found.replaced != nil {
            found.keepBoth = Result { try places.move.destinations(folder: folder, files: files) }
        }
        return found
    }

    /// The upgrade's old files `sharePaths`, as the index has them, each placed on the release
    /// by the matcher, as the new files are. With `heldToRelease`, as for an upgrade the owner
    /// queued, each must carry `release`; otherwise each is held to the one it carries now.
    private static func positioned(
        _ sharePaths: [String], release: Int, heldToRelease: Bool, places: ImportPlaces,
        databaseURL: URL, catalog: URL?
    ) async throws -> [UpgradeOldFile] {
        guard let catalog else {
            throw ReleaseSnapshot.Problem.notInCatalog(releaseID: release)
        }
        let read = await blockingFileWork {
            Result { () throws -> ([UpgradeOldFile], DiscogsAlbum, [String: Int64]) in
                let index = try LibraryIndex(at: databaseURL)
                let old =
                    heldToRelease
                    ? try index.upgradeOldFiles(
                        sharePaths, release: release, shareRoot: places.shareRoot)
                    : try index.upgradeOldFiles(sharePaths, shareRoot: places.shareRoot)
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
