import Foundation

/// Which snapshots are kept (ADR 0142): of the day's, the newest `dailyKept`, then for each of
/// the `weeklyKept` ISO weeks before the oldest of those, the newest in that week, a month of
/// history in 11 files; and the newest `beforeRestoreKept` written before a restore.
enum SnapshotRotation {
    static let dailyKept = 7
    static let weeklyKept = 4
    static let beforeRestoreKept = 3

    /// The names among `names` that rotation deletes, with weeks and days in `calendar`'s time
    /// zone.
    static func expired(_ names: [SnapshotName], calendar: Calendar = .current) -> [SnapshotName] {
        let unique = Set(names)
        let beforeRestore = unique.filter { $0.beforeRestoreTime != nil }.sorted(by: >)
        return Array(beforeRestore.dropFirst(beforeRestoreKept))
            + expiredDays(unique.filter { $0.beforeRestoreTime == nil }, calendar)
    }

    private static func expiredDays(_ names: Set<SnapshotName>, _ calendar: Calendar)
        -> [SnapshotName]
    {
        let newestFirst = names.sorted(by: >)
        guard newestFirst.count > dailyKept else { return [] }
        let daily = newestFirst.prefix(dailyKept)
        var weeks = Calendar(identifier: .iso8601)
        weeks.timeZone = calendar.timeZone
        func week(_ name: SnapshotName) -> Date? {
            weeks.dateInterval(of: .weekOfYear, for: name.date(in: weeks))?.start
        }
        guard let oldestDaily = daily.last, let lastWeek = week(oldestDaily) else { return [] }
        let keptWeeks = Set(
            (1...weeklyKept).compactMap {
                weeks.date(byAdding: .weekOfYear, value: -$0, to: lastWeek)
            })
        var kept = Set(daily)
        var weeksFilled: Set<Date> = []
        // Newest first, so the first of each week is its newest.
        for name in newestFirst.dropFirst(dailyKept) {
            guard let start = week(name), keptWeeks.contains(start),
                weeksFilled.insert(start).inserted
            else { continue }
            kept.insert(name)
        }
        return newestFirst.filter { !kept.contains($0) }
    }
}
