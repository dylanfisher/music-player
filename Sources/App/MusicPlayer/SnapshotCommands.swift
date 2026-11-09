import AppKit
import Foundation
import Library
import SQLite
import Settings
import SettingsWindow
import Snapshot

/// The library's daily snapshots, Back Up Now and Restore… (ADR 0142): each runs between the
/// watcher's scans, so never during a scan or sync. Restore… stops a running scan first.
extension AppDelegate {
    /// How often the app asks for the day's snapshot after the launch's: once the day changes,
    /// the next ask writes it.
    static let snapshotCheckSeconds = 3600.0
    /// What the alert says when a restore fails, before or at the launch that applies it.
    static let restoreFailedTitle = "The snapshot couldn't be restored"

    /// The snapshot folder the settings give now.
    var snapshotFolder: URL? { settings.map { paths.snapshotDirectory($0[\.snapshotFolder]) } }

    /// Runs `job` between the watcher's scans, or on a queue of its own while nothing is
    /// watched, so nothing scans.
    func betweenScans(_ job: @escaping @Sendable () -> Void) {
        if let watcher {
            watcher.betweenScans(job)
        } else {
            DispatchQueue.global(qos: .utility).async(execute: job)
        }
    }

    /// Queues the day's snapshot unless one waits already.
    func scheduleDailySnapshot() {
        guard let folder = snapshotFolder, let job = snapshotScheduler?.dailyJob(into: folder)
        else { return }
        betweenScans(job)
    }

    /// Asks for the day's snapshot now, as the launch's scans have ended, and every
    /// `snapshotCheckSeconds` after.
    func startDailySnapshots() {
        guard snapshotTimer == nil else { return }
        scheduleDailySnapshot()
        snapshotTimer = Timer.scheduledTimer(
            withTimeInterval: Self.snapshotCheckSeconds, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDailySnapshot() }
        }
    }

    /// `events`, and the daily snapshots started once the watcher's scans at launch have ended.
    func startingSnapshotsAfterLaunch(
        _ events: @escaping @Sendable (WatcherEvent) -> Void
    ) -> @Sendable (WatcherEvent) -> Void {
        { [weak self] event in
            events(event)
            guard case .launchScansEnded = event else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.startDailySnapshots() }
            }
        }
    }

    /// Puts a prepared restore in place, then holds the index in use for as long as the app
    /// runs. What happened is told once the window is up, since `fail` quits a launch that has
    /// none. An index a failed restore couldn't move back throws, so none is opened.
    func applyRestoreAtLaunch() throws {
        let databaseURL = libraryFileURL(in: paths.dataDirectory)
        let outcome: Result<PendingRestore, any Error>
        do {
            outcome = .success(try applyPendingRestore(paths: paths))
        } catch let error as Snapshot.SnapshotError {
            if case .indexNotPutBack = error { throw error }
            outcome = .failure(error)
        } catch {
            outcome = .failure(error)
        }
        indexInUse = try IndexInUse(databaseURL: databaseURL)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.tell(outcome) }
        }
    }

    private func tell(_ outcome: Result<PendingRestore, any Error>) {
        let alert = NSAlert()
        switch outcome {
        case .success(.none): return
        case .success(.applied(let name)):
            alert.messageText = "The library was restored from \(name)"
            alert.informativeText =
                "The library, layout and settings as they were before are in the snapshot folder,"
                + " as the snapshot marked “before a restore”."
        case .success(.waiting(let reason)):
            alert.messageText = "The snapshot wasn't restored yet"
            alert.informativeText =
                "\(reason.prefix(1).uppercased() + reason.dropFirst()). It's"
                + " restored at the next launch."
        case .failure(let error):
            return fail(Self.restoreFailedTitle, error)
        }
        alert.runModal()
    }

    /// The index's place and size and the snapshots, read off the main actor.
    func libraryDatabase() async throws -> LibraryDatabase {
        guard let folder = snapshotFolder else { throw CancellationError() }
        let databaseURL = libraryFileURL(in: paths.dataDirectory)
        let lastProblem = snapshotScheduler?.lastProblem
        return try await Task.detached {
            LibraryDatabase(
                indexPath: databaseURL.path, indexBytes: try Database.sizeBytes(at: databaseURL),
                snapshots: try snapshots(in: folder).map {
                    LibraryDatabase.Snapshot(
                        path: $0.url.path, day: $0.day, written: $0.written, bytes: $0.bytes,
                        beforeRestore: $0.isBeforeRestore)
                }, lastProblem: lastProblem)
        }.value
    }

    /// Back Up Now: the day's snapshot, written between scans whether or not there is one.
    func backUpNow() async {
        guard let scheduler = snapshotScheduler, let folder = snapshotFolder else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            betweenScans {
                scheduler.write(into: folder, now: Date())
                continuation.resume()
            }
        }
    }

    /// Restore…: asks over `window`, then stops watching, and a running scan with it, prepares
    /// the restore and relaunches.
    func confirmRestoring(_ snapshot: LibraryDatabase.Snapshot, over window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Replace the library with the snapshot of \(snapshot.day)?"
        alert.informativeText =
            "Plays, ratings and playlists in it replace the current ones, and so do the window"
            + " layout and settings it kept; the Discogs and service tokens stay as they are now."
            + " The library, layout and settings as they are now are snapshotted first, and the"
            + " app quits and opens again to make the change."
            + (browser?.isScanning == true ? " The scan running now stops first." : "")
        alert.addButton(withTitle: "Restore and Relaunch")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.restore(snapshot)
        }
    }

    private func restore(_ snapshot: LibraryDatabase.Snapshot) {
        guard let folder = snapshotFolder else { return }
        let paths = self.paths
        let source = URL(fileURLWithPath: snapshot.path, isDirectory: false)
        let job: @Sendable () -> Void = { [weak self] in
            let prepared = Result {
                try prepareRestore(
                    of: source, paths: paths, snapshotFolder: folder, now: Date())
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch prepared {
                    case .success:
                        self?.relaunch(
                            failing: "The app couldn't open again; open it to finish the restore")
                    case .failure(let error):
                        self?.fail(Self.restoreFailedTitle, error)
                        // The app goes on, so it watches the folders again.
                        if let self, let settings = self.settings { self.startWatching(settings) }
                    }
                }
            }
        }
        // Not behind a running scan, which may have far to go on a share.
        if let watcher {
            watcher.stop(then: job)
        } else {
            betweenScans(job)
        }
    }
}
