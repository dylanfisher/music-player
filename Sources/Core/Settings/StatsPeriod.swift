import Foundation

/// The time Listening Stats counts plays in (ADR 0102, 0109). The rolling periods are the last
/// 7, 30 or 365 days up to the moment the stats are read, today included, in the local calendar
/// and its time zone.
public enum StatsPeriod: Hashable, Sendable {
    /// The last 7 days.
    case week
    /// The last 30 days.
    case month
    /// The last 365 days.
    case year
    /// One whole year, such as 2024.
    case chosenYear(Int)
    case all

    /// The years `chosenYear` takes: well past any play's date, so a typed year can't overflow.
    public static let years = 1900...9999

    /// The period as a saved source and the command line write it: `week`, `month`, `year`,
    /// `all` or the year's number.
    public var text: String {
        switch self {
        case .week: "week"
        case .month: "month"
        case .year: "year"
        case .chosenYear(let year): String(year)
        case .all: "all"
        }
    }

    /// Reads `text`, in any case; nil for anything else.
    public init?(text: some StringProtocol) {
        switch text.lowercased() {
        case "week": self = .week
        case "month": self = .month
        case "year": self = .year
        case "all": self = .all
        default:
            guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let year = Int(text),
                Self.years.contains(year)
            else { return nil }
            self = .chosenYear(year)
        }
    }

    /// What the command line's help says `--period` takes.
    public static let textHelp = "week, month, year, all or a year such as 2024"

    /// The period's name in the picker and the panel.
    public var title: String {
        switch self {
        case .week: "Past Week"
        case .month: "Past Month"
        case .year: "Past Year"
        case .chosenYear(let year): String(year)
        case .all: "All Time"
        }
    }

    /// The seconds the period covers at `now`; nil for All Time, which has no bounds.
    public func span(now: Date = Date(), calendar: Calendar = .current) -> PlaySpan? {
        let interval: DateInterval?
        switch self {
        case .week: interval = Self.days(7, upTo: now, calendar: calendar)
        case .month: interval = Self.days(30, upTo: now, calendar: calendar)
        case .year: interval = Self.days(365, upTo: now, calendar: calendar)
        case .chosenYear(let year):
            let midYear = calendar.date(from: DateComponents(year: year, month: 7, day: 1))
            interval = midYear.flatMap { calendar.dateInterval(of: .year, for: $0) }
        case .all: return nil
        }
        guard let interval else {
            preconditionFailure("the calendar has no \(text) holding \(now)")
        }
        return PlaySpan(interval)
    }

    /// The local days `count` long that end with the one holding `now`: from the first's
    /// midnight to the next day's, so a bar of a day is a whole day.
    private static func days(_ count: Int, upTo now: Date, calendar: Calendar) -> DateInterval? {
        guard let today = calendar.dateInterval(of: .day, for: now),
            let first = calendar.date(byAdding: .day, value: 1 - count, to: today.start)
        else { return nil }
        return DateInterval(start: first, end: today.end)
    }

    /// The year the period is, for Year in Review: the one `now` is in for Past Year, or the
    /// chosen one.
    public func reviewYear(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        switch self {
        case .year: calendar.component(.year, from: now)
        case .chosenYear(let year): year
        case .week, .month, .all: nil
        }
    }
}
