import Foundation
import OSLog

/// This run's log lines from the modules named in `categories` over the last `seconds`, oldest
/// first, as `10:41:07.215 HALOutput error: …`, for a bug report. A value logged without
/// `privacy: .public` reads as `<private>`. Opening the store takes seconds, so call it off the
/// main thread.
public func recentLogLines(categories: Set<String>, seconds: Double) throws -> [String] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let entries = try store.getEntries(
        at: store.position(date: Date(timeIntervalSinceNow: -seconds)),
        matching: NSPredicate(
            format: "subsystem == %@ AND category IN %@", bundleIdentifier, Array(categories)))
    let time = DateFormatter()
    time.dateFormat = "HH:mm:ss.SSS"
    return entries.compactMap { entry in
        guard let entry = entry as? OSLogEntryLog else { return nil }
        return "\(time.string(from: entry.date)) \(entry.category) \(name(of: entry.level)):"
            + " \(entry.composedMessage)"
    }
}

private func name(of level: OSLogEntryLog.Level) -> String {
    switch level {
    case .debug: "debug"
    case .info: "info"
    case .notice: "notice"
    case .error: "error"
    case .fault: "fault"
    case .undefined: "log"
    @unknown default: "log"
    }
}
