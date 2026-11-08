import Foundation

/// A snapshot's file name, `library-YYYY-MM-DD.sqlite.gz`, by the local day it was written
/// (ADR 0142). One a day: a second the same day replaces the first.
public struct SnapshotName: Hashable, Comparable, Sendable {
    /// `YYYY-MM-DD`, which sorts as the days do.
    public let day: String

    private static let prefix = "library-"
    private static let suffix = ".sqlite.gz"
    /// What a snapshot's file is called while it's written, before the rename that finishes it.
    private static let partialSuffix = ".partial"

    /// The name for the local day `date` falls on.
    init(of date: Date, calendar: Calendar = .current) {
        day = Self.dayFormatter(calendar.timeZone).string(from: date)
    }

    /// The name `fileName` is, or nil for any other file.
    init?(fileName: String) {
        guard fileName.hasPrefix(Self.prefix), fileName.hasSuffix(Self.suffix) else { return nil }
        let day = String(fileName.dropFirst(Self.prefix.count).dropLast(Self.suffix.count))
        // A day that formats back the same, so `library-2026-1-5.sqlite.gz` isn't one. In UTC,
        // which has a midnight every day; some zones skip one for daylight saving time.
        let formatter = Self.dayFormatter(utc)
        guard let date = formatter.date(from: day), formatter.string(from: date) == day
        else { return nil }
        self.day = day
    }

    var fileName: String { Self.prefix + day + Self.suffix }

    /// The gzip file while it's written.
    var partialFileName: String { fileName + Self.partialSuffix }

    /// The index's copy, before it's compressed. Hidden, as Finder shows the folder.
    var copyFileName: String { "." + Self.prefix + day + ".sqlite" + Self.partialSuffix }

    /// Whether `fileName` is a file the writer leaves only when it's stopped partway.
    static func isPartial(_ fileName: String) -> Bool {
        guard fileName.hasSuffix(partialSuffix) else { return false }
        let name = String(fileName.dropLast(partialSuffix.count))
        if SnapshotName(fileName: name) != nil { return true }
        guard name.hasPrefix("."), name.hasSuffix(".sqlite") else { return false }
        return SnapshotName(fileName: String(name.dropFirst().dropLast(".sqlite".count)) + suffix)
            != nil
    }

    /// The start of the day in `calendar`.
    func date(in calendar: Calendar) -> Date {
        guard let midnight = Self.dayFormatter(utc).date(from: day) else {
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

    public static func < (lhs: SnapshotName, rhs: SnapshotName) -> Bool { lhs.day < rhs.day }

    /// `YYYY-MM-DD` in `timeZone`, whatever the user's locale and calendar.
    private static func dayFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// Every day has a midnight in UTC.
private let utc = TimeZone(secondsFromGMT: 0)!
