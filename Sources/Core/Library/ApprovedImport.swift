import Darwin
import Foundation
import Metadata
import Recommender

/// A staged job the owner approved (ADR 0139): the files to move into the library and, for an
/// upgrade, the files they replace.
package struct ApprovedImport: Sendable {
    /// What an upgrade replaces, as the Approve sheet showed it.
    package struct Upgrade: Sendable {
        /// The old files, each with its release position, as the sheet resolved them.
        var old: [UpgradeOldFile]
        /// The share paths of the unmatched old files the owner ticked to lose.
        var acknowledged: Set<String>

        package init(old: [UpgradeOldFile], acknowledged: Set<String>) {
            self.old = old
            self.acknowledged = acknowledged
        }
    }

    package var jobID: Int
    package var releaseID: Int
    /// As the service last listed it: `staged`, `approved` or `importing`.
    package var state: JobState
    /// The job's folder in the staging folder.
    var folder: String
    var files: [DownloadJob.File]
    var upgrade: Upgrade?

    package init(
        jobID: Int, releaseID: Int, state: JobState, folder: String, files: [DownloadJob.File],
        upgrade: Upgrade?
    ) {
        self.jobID = jobID
        self.releaseID = releaseID
        self.state = state
        self.folder = folder
        self.files = files
        self.upgrade = upgrade
    }
}

extension ApprovedImport {
    /// The job's files with the sizes they have since the player's tag write, where one was
    /// recorded, else the sizes the service staged. The service's sizes are fixed at staging,
    /// and a tag write can grow a file when its padding runs out.
    func sizedAfterTagging(by index: LibraryIndex) throws -> [DownloadJob.File] {
        try index.sizedAfterTagging(files, job: jobID, folder: folder)
    }
}

extension LibraryIndex {
    /// `files` of the staged folder `folder` of the job `job`, with the sizes recorded after
    /// the player's tag write where there are any, else the ones the service staged them with.
    package func sizedAfterTagging(_ files: [DownloadJob.File], job: Int, folder: String) throws
        -> [DownloadJob.File]
    {
        let recorded = try stagedSizes(job: job, folder: folder)
        return files.map { file in
            var file = file
            file.sizeBytes = recorded[file.name] ?? file.sizeBytes
            return file
        }
    }
}

/// How an import run ended.
package enum ImportOutcome: Equatable, Sendable {
    /// Every file is in the library at these paths, and `imported` is in the outbox.
    case imported([String])
    /// Nothing was started, and nothing reported.
    case refused(String)
    /// Stopped at `stage`, which the outbox reports; Retry runs the steps again from there.
    case failed(HandoffEvent.Stage, String)
}

/// Runs Approve's steps (ADR 0139) for one job, as an idempotent sequence over the index's
/// ledger and outbox: report (and hear the service accept it), move the new files in, and for an upgrade check them, delete the
/// old files and carry their stats; then rescan and report `imported`. Each step works out
/// from the ledger and the file system what's left of it, so a run after a crash or a failure,
/// on this Mac or another, finishes what the last one began. The ledger stays until the outbox
/// has delivered `imported`, whose sender forgets it. One runs at a time, since the library
/// folder has one writer. Blocks on the volumes between its awaits.
package struct ImportRun {
    let index: LibraryIndex
    let move: LibraryFolderMove
    /// `moveToTrash`, giving its failure: the files it was given that are still there count
    /// as refused, whatever it says.
    let trash: @Sendable ([URL]) async -> String?
    /// `LibraryWatcher.importMoves(lines:)`.
    let carry: @Sendable ([(from: String, to: String)]) async throws -> MoveListImport
    /// `LibraryWatcher.rescan(directories:)`.
    let rescan: @Sendable ([String]) -> Void
    /// Sends the outbox to the service, which must answer `approved` and `importing` before the
    /// first file moves. Nil when it did, else why not.
    let deliver: @Sendable () async -> String?

    package init(
        index: LibraryIndex, move: LibraryFolderMove,
        trash: @escaping @Sendable ([URL]) async -> String?,
        carry: @escaping @Sendable ([(from: String, to: String)]) async throws -> MoveListImport,
        rescan: @escaping @Sendable ([String]) -> Void,
        deliver: @escaping @Sendable () async -> String?
    ) {
        self.index = index
        self.move = move
        self.trash = trash
        self.carry = carry
        self.rescan = rescan
        self.deliver = deliver
    }

    package func run(_ job: ApprovedImport) async -> ImportOutcome {
        do {
            if try reported(.imported, job) {
                return .imported(try destinations(job))
            }
            if let refusal = try refusal(job) { return .refused(refusal) }
            try dropFailures(job)
            if job.state == .staged { try report(.approved, job) }
            try report(.importing, job)
        } catch {
            return .refused("\(error)")
        }
        // The service has to know before the first rename, and can refuse: another Mac may
        // have rejected the job, or its tagging may not be clean.
        if let refusal = await deliver() { return .refused(refusal) }

        let destinations: [String]
        let sizes: [DownloadJob.File]
        do {
            sizes = try job.sizedAfterTagging(by: index)
            destinations = try move.moveIn(
                job: job.jobID, release: job.releaseID, folder: job.folder,
                files: sizes.map { ($0.name, $0.sizeBytes) }, ledger: index)
        } catch {
            return fail(.move, "\(error)", job)
        }
        var directories = Set(destinations.map(parentOf))
        if let upgrade = job.upgrade {
            if let problem = verify(destinations, sizes) { return fail(.move, problem, job) }
            let old: [ImportStep]
            do {
                old = try ledgerOldFiles(upgrade, destinations, job)
            } catch {
                return fail(.move, "\(error)", job)
            }
            if let problem = await delete(old, job) { return fail(.delete, problem, job) }
            if let problem = await carryStats(old) { return fail(.carry, problem, job) }
            directories.formUnion(old.map { parentOf(move.shareRoot + "/" + $0.path) })
        }
        rescan(directories.sorted())
        do {
            try report(.imported, job)
        } catch {
            return fail(.carry, "\(error)", job)
        }
        return .imported(destinations)
    }

    /// Why the job can't be approved as it stands, before anything is done.
    private func refusal(_ job: ApprovedImport) throws -> String? {
        guard [.staged, .approved, .importing].contains(job.state) else {
            return "the job is \(job.state.rawValue), not staged or approving"
        }
        guard let upgrade = job.upgrade else { return nil }
        // Once the old files are in the ledger, it holds what the sheet chose.
        guard try index.importSteps(job: job.jobID).allSatisfy({ $0.kind != .trashed }) else {
            return nil
        }
        let mapping = UpgradeMapping(old: upgrade.old, new: newPositions(job))
        let unticked = mapping.unmatched.filter { !upgrade.acknowledged.contains($0.sharePath) }
        guard unticked.isEmpty else {
            return "these old files have no new one, and aren't ticked to lose: "
                + unticked.map(\.sharePath).joined(separator: ", ")
        }
        return nil
    }

    /// Each moved file read again: its tags read, its size the one it was staged with (after the
    /// player's tag write, when it made one), and as many
    /// as the job has. Nil when they all hold.
    private func verify(_ destinations: [String], _ files: [DownloadJob.File]) -> String? {
        guard destinations.count == files.count else {
            return "\(destinations.count) files moved, the job has \(files.count)"
        }
        for (path, file) in zip(destinations, files) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return "\(path) isn't there" }
            guard Int(info.st_size) == file.sizeBytes else {
                return "\(path) is \(info.st_size) bytes, not the \(file.sizeBytes) staged"
            }
            do {
                _ = try readMetadata(at: URL(fileURLWithPath: path, isDirectory: false))
            } catch {
                return MoveRefusal.unreadable(path, "\(error)").description
            }
        }
        return nil
    }

    /// The old files to delete, each with the new file its stats go to, from the ledger, or
    /// put there from the sheet's choice on the first run that gets this far.
    private func ledgerOldFiles(
        _ upgrade: ApprovedImport.Upgrade, _ destinations: [String], _ job: ApprovedImport
    ) throws -> [ImportStep] {
        let ledgered = try index.importSteps(job: job.jobID)
        if ledgered.contains(where: { $0.kind == .trashed }) {
            let carried = Dictionary(
                ledgered.filter { $0.kind == .carried }.map { ($0.path, $0.destination) },
                uniquingKeysWith: { one, _ in one })
            return ledgered.filter { $0.kind == .trashed }.map { step in
                var step = step
                step.destination = carried[step.path] ?? nil
                return step
            }
        }
        let newByName = Dictionary(
            zip(job.files.map(\.name), destinations), uniquingKeysWith: { one, _ in one })
        let mapping = UpgradeMapping(old: upgrade.old, new: newPositions(job))
        let pairs = Dictionary(
            mapping.pairs.map { ($0.old, $0.new) }, uniquingKeysWith: { one, _ in one })
        let steps = try upgrade.old.map { file in
            ImportStep(
                jobID: job.jobID, releaseID: job.releaseID, kind: .trashed, path: file.sharePath,
                destination: try pairs[file.sharePath].flatMap { newByName[$0] }.map(
                    shareRelative))
        }
        try index.database.transaction {
            for step in steps {
                try index.recordImportStep(
                    ImportStep(
                        jobID: step.jobID, releaseID: step.releaseID, kind: .trashed,
                        path: step.path))
                if step.destination != nil {
                    var carried = step
                    carried.kind = .carried
                    try index.recordImportStep(carried)
                }
            }
        }
        return steps
    }

    /// Gives the old files still there to the Trash. A file counts as gone when it's no longer
    /// at its path (ADR 0125), which on a share with no Trash is a permanent delete. Each must
    /// still be the release's track in the index. Nil when they're all gone.
    private func delete(_ old: [ImportStep], _ job: ApprovedImport) async -> String? {
        let left = old.map { move.shareRoot + "/" + $0.path }.filter(pathExists)
        guard !left.isEmpty else { return nil }
        do {
            _ = try index.upgradeOldFiles(
                left.map { String($0.dropFirst(stem(move.shareRoot).count + 1)) },
                release: job.releaseID, shareRoot: move.shareRoot)
        } catch {
            return "\(error)"
        }
        let failure = await trash(left.map { URL(fileURLWithPath: $0, isDirectory: false) })
        let refused = left.filter(pathExists)
        guard refused.isEmpty else {
            return "the Trash refused " + refused.joined(separator: ", ")
                + (failure.map { ": \($0)" } ?? "")
        }
        return nil
    }

    /// Moves each old file's stats to its new one. Nil when every line moved, or a run before
    /// moved it.
    private func carryStats(_ old: [ImportStep]) async -> String? {
        let lines = old.compactMap { step in
            step.destination.map {
                (from: move.shareRoot + "/" + step.path, to: move.shareRoot + "/" + $0)
            }
        }
        guard !lines.isEmpty else { return nil }
        do {
            let result = try await carry(lines)
            guard result.problems.isEmpty else {
                return result.problems.map(\.description)
                    .joined(separator: "; ")
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// The new files' positions, as the service matched them and the clean tag run confirmed.
    private func newPositions(_ job: ApprovedImport) -> [(name: String, position: String?)] {
        job.files.map { ($0.name, $0.position) }
    }

    /// The files' paths in the library, from the ledger, for a job already imported.
    private func destinations(_ job: ApprovedImport) throws -> [String] {
        let moved = try index.importSteps(job: job.jobID).filter { $0.kind == .moved }
        let byPath = Dictionary(
            moved.map { ($0.path, $0.destination) }, uniquingKeysWith: { one, _ in one })
        return job.files.compactMap { file in
            byPath[job.folder + "/" + file.name].flatMap { $0 }.map { move.shareRoot + "/" + $0 }
        }
    }

    /// Queues `stage` as failed, and returns it.
    private func fail(_ stage: HandoffEvent.Stage, _ reason: String, _ job: ApprovedImport)
        -> ImportOutcome
    {
        do {
            try report(.failed(stage, reason: reason), job)
        } catch {
            return .failed(stage, "\(reason), and the failure couldn't be queued: \(error)")
        }
        return .failed(stage, reason)
    }

    /// Queues `event` for the job unless it's waiting already: the service answers a repeat
    /// with the job unchanged.
    private func report(_ event: HandoffEvent, _ job: ApprovedImport) throws {
        guard try !reported(event, job) else { return }
        _ = try index.queueImportReport(job: job.jobID, release: job.releaseID, body: event.json)
    }

    private func reported(_ event: HandoffEvent, _ job: ApprovedImport) throws -> Bool {
        try index.importReports().contains { $0.jobID == job.jobID && $0.body == event.json }
    }

    /// Drops a failure a run before queued and the service hasn't had: this run supersedes
    /// it, and the service would refuse `importing` after it.
    private func dropFailures(_ job: ApprovedImport) throws {
        for report in try index.importReports() where report.jobID == job.jobID {
            if report.body.contains(#""type":"failed""#) {
                try index.removeImportReport(report.seq)
            }
        }
    }

    private func shareRelative(_ path: String) throws -> String {
        guard isPath(path, under: move.shareRoot) else {
            throw MoveRefusal.outsideShare(path, move.shareRoot)
        }
        return String(path.dropFirst(stem(move.shareRoot).count + 1))
    }
}

private func parentOf(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
