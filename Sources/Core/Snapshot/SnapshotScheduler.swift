import Foundation
import Library
import Log

private let logger = moduleLogger()

/// Writes a snapshot of the index once a day, and when asked, and rotates the folder after
/// each (ADR 0142). The app runs its jobs between scans, on the watcher's scan queue, so never
/// during a scan or sync. What it knows of the last snapshot comes from the folder, so nothing
/// is stored, except why the last try failed, which lasts as long as the app runs.
public final class SnapshotScheduler: @unchecked Sendable {
    private let databaseURL: URL
    /// Guards the fields below it.
    private let lock = NSLock()
    private var failure: String?
    /// Whether a daily job is waiting to run, so a second ask doesn't queue another.
    private var queued = false

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    /// Why the last snapshot failed, or nil when the last one tried was written.
    public var lastFailure: String? { lock.withLock { failure } }

    /// A job that writes the day's snapshot into `folder` unless it has one, for the caller to
    /// run between scans; nil while an earlier one hasn't run, so a second ask queues nothing.
    public func dailyJob(into folder: URL) -> (@Sendable () -> Void)? {
        let first = lock.withLock {
            defer { queued = true }
            return !queued
        }
        guard first else { return nil }
        return { [self] in
            lock.withLock { queued = false }
            writeIfDue(into: folder, now: Date())
        }
    }

    /// Writes the day `now` falls on's snapshot into `folder`, unless the folder has one, and
    /// rotates. Returns whether it wrote one.
    @discardableResult
    func writeIfDue(into folder: URL, now: Date) -> Bool {
        let today = SnapshotName(of: now)
        do {
            if try snapshots(in: folder).contains(where: { $0.name == today }) { return false }
        } catch {
            record(error)
            return false
        }
        return write(into: folder, now: now)
    }

    /// Back Up Now: writes the snapshot of the day `now` falls on into `folder`, replacing the
    /// day's, and rotates. Returns whether it worked; `lastFailure` says why not.
    @discardableResult
    public func write(into folder: URL, now: Date) -> Bool {
        do {
            try writeSnapshot(of: try LibraryIndex(at: databaseURL), into: folder, on: now)
            try rotateSnapshots(in: folder)
            lock.withLock { failure = nil }
            return true
        } catch {
            record(error)
            return false
        }
    }

    private func record(_ error: any Error) {
        logger.error("couldn't snapshot the library: \(error)")
        lock.withLock { failure = "\(error)" }
    }
}
