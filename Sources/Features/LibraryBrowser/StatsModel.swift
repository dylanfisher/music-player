import Foundation
import Library
import Log
import Settings

private let logger = moduleLogger()

/// Listening Stats' logic, apart from AppKit (ADR 0102): the period shown, the ranking, and the
/// report read for them off the main thread. Each read takes a session number; one a newer
/// read started after is dropped when it ends, so a slow All Time never replaces the week
/// chosen after it. Until a period's report arrives the last one stays, marked as loading.
@MainActor
final class StatsModel {
    private(set) var period = StatsPeriod.month
    /// What the top lists rank by; both rankings are in each report, so a change reads nothing.
    var ranking = StatsReport.Ranking.plays {
        didSet { if ranking != oldValue { changed() } }
    }
    /// The report of `period`, or of the period before it while that one loads.
    private(set) var report: StatsReport?
    private(set) var isLoading = false
    /// Called after the period, the report, the ranking or the loading change.
    var changed: () -> Void = {}
    var failed: (String) -> Void = { _ in }

    private let read: @MainActor (StatsPeriod) async throws -> StatsReport
    private var session = 0

    /// `read` builds a period's report off the main thread.
    init(read: @escaping @MainActor (StatsPeriod) async throws -> StatsReport) {
        self.read = read
    }

    /// Shows `period`, reading its report: again when it's the one shown, since plays may
    /// have been added.
    func show(_ period: StatsPeriod) async {
        session += 1
        let mine = session
        self.period = period
        isLoading = true
        changed()
        do {
            let report = try await read(period)
            guard mine == session else { return }
            self.report = report
            isLoading = false
            changed()
        } catch {
            guard mine == session else { return }
            isLoading = false
            logger.error("couldn't read the listening stats: \(error)")
            failed("couldn't read the listening stats: \(error)")
            changed()
        }
    }

    /// The years the year menu offers: from the first play with a date to `now`'s, latest
    /// first; this year alone before any play.
    func years(now: Date = Date(), calendar: Calendar = .current) -> [Int] {
        let thisYear = calendar.component(.year, from: now)
        let first =
            report?.earliestPlay.map {
                calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval($0)))
            } ?? thisYear
        return Array((min(first, thisYear)...thisYear).reversed())
    }
}
