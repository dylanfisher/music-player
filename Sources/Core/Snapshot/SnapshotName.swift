import Foundation

/// A snapshot's file name, by the local day it was written (ADR 0142): the day's,
/// `library-YYYY-MM-DD.sqlite.gz`, one a day, a second replacing the first; or one a restore
/// writes of the index it replaces, `library-YYYY-MM-DD-before-restore-HHMMSS.sqlite.gz`,
/// which never takes a day's name.
struct SnapshotName: Hashable, Comparable, Sendable {
    /// `YYYY-MM-DD`, which sorts as the days do.
    let day: String
    /// `HHMMSS` for a snapshot before a restore; nil for the day's.
    let beforeRestoreTime: String?

    private static let prefix = "library-"
    private static let suffix = ".sqlite.gz"
    private static let beforeRestore = "-before-restore-"
    /// What a snapshot's file is called while it's written, before the rename that finishes it.
    private static let partialSuffix = ".partial"

    /// The name for the local day `date` falls on, or with `beforeRestore`, for its second.
    init(of date: Date, beforeRestore: Bool = false, calendar: Calendar = .current) {
        day = Self.formatter("yyyy-MM-dd", calendar.timeZone).string(from: date)
        beforeRestoreTime =
            beforeRestore ? Self.formatter("HHmmss", calendar.timeZone).string(from: date) : nil
    }

    /// The name `fileName` is, or nil for any other file.
    init?(fileName: String) {
        guard fileName.hasPrefix(Self.prefix), fileName.hasSuffix(Self.suffix) else { return nil }
        let middle = String(fileName.dropFirst(Self.prefix.count).dropLast(Self.suffix.count))
        let parts = middle.components(separatedBy: Self.beforeRestore)
        // Each part formats back the same, so `library-2026-1-5.sqlite.gz` isn't one. In UTC,
        // which has a midnight every day; some zones skip one for daylight saving time.
        func exact(_ text: String, _ format: String) -> Bool {
            let formatter = Self.formatter(format, utc)
            return formatter.date(from: text).map(formatter.string) == text
        }
        guard parts.count <= 2, exact(parts[0], "yyyy-MM-dd"),
            parts.count == 1 || exact(parts[1], "HHmmss")
        else { return nil }
        day = parts[0]
        beforeRestoreTime = parts.count == 2 ? parts[1] : nil
    }

    var fileName: String {
        Self.prefix + day + (beforeRestoreTime.map { Self.beforeRestore + $0 } ?? "") + Self.suffix
    }

    /// The gzip file while one write, `token`, writes it. Hidden, as Finder shows the folder,
    /// and the write's own, so two writes never share a file.
    func partialFileName(_ token: String) -> String {
        "." + Self.prefix + day + "-" + token + Self.suffix + Self.partialSuffix
    }

    /// The index's copy for one write, `token`, before it's compressed.
    func copyFileName(_ token: String) -> String {
        "." + Self.prefix + day + "-" + token + ".sqlite" + Self.partialSuffix
    }

    /// Whether `fileName` is a file a write makes and deletes, left only when it's stopped
    /// partway.
    static func isPartial(_ fileName: String) -> Bool {
        fileName.hasPrefix("." + prefix) && fileName.hasSuffix(partialSuffix)
    }

    /// The start of the day in `calendar`.
    func date(in calendar: Calendar) -> Date {
        guard let midnight = Self.formatter("yyyy-MM-dd", utc).date(from: day) else {
            preconditionFailure("\(day) was checked as a day when the name was made")
        }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: midnight)
        guard let date = calendar.date(from: parts) else {
            preconditionFailure("\(day) has no start in \(calendar.identifier)")
        }
        return date
    }

    /// By day, then a day's before its snapshots before a restore, by time.
    static func < (lhs: SnapshotName, rhs: SnapshotName) -> Bool {
        (lhs.day, lhs.beforeRestoreTime ?? "") < (rhs.day, rhs.beforeRestoreTime ?? "")
    }

    /// `format` in `timeZone`, whatever the user's locale and calendar.
    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

/// Every day has a midnight in UTC.
private let utc = TimeZone(secondsFromGMT: 0)!
