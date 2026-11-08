import Foundation

/// Which snapshots are kept: the newest `dailyKept`, then for each of the `weeklyKept` ISO weeks
/// before the oldest of those, the newest in that week (ADR 0142). A month of history in 11
/// files.
enum SnapshotRotation {
    static let dailyKept = 7
    static let weeklyKept = 4

    /// The names among `names` that rotation deletes, with weeks and days in `calendar`'s time
    /// zone.
    static func expired(_ names: [SnapshotName], calendar: Calendar = .current) -> [SnapshotName] {
        let newestFirst = Set(names).sorted(by: >)
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
