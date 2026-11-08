import Foundation
import Library
import Settings
import Snapshot

/// The library's daily snapshots and Back Up Now (ADR 0142): each runs between the watcher's
/// scans, so never during a scan or sync.
extension AppDelegate {
    /// How often the app asks for the day's snapshot after the launch's: once the day changes,
    /// the next ask writes it.
    static let snapshotCheckSeconds = 3600.0

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
}
