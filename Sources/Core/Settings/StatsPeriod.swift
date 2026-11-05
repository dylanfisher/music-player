import Foundation

/// The time Listening Stats counts plays in (ADR 0102). The calendar periods are the ones that
/// hold the moment the stats are read, in the local calendar, its time zone and its first
/// weekday.
public enum StatsPeriod: Hashable, Sendable {
    case week
    case month
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
        case .week: "This Week"
        case .month: "This Month"
        case .year: "This Year"
        case .chosenYear(let year): String(year)
        case .all: "All Time"
        }
    }

    /// The seconds the period covers at `now`; nil for All Time, which has no bounds.
    public func span(now: Date = Date(), calendar: Calendar = .current) -> PlaySpan? {
        let interval: DateInterval?
        switch self {
        case .week: interval = calendar.dateInterval(of: .weekOfYear, for: now)
        case .month: interval = calendar.dateInterval(of: .month, for: now)
        case .year: interval = calendar.dateInterval(of: .year, for: now)
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

    /// The year the period is, for Year in Review: This Year's at `now`, or the chosen one.
    public func reviewYear(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        switch self {
        case .year: calendar.component(.year, from: now)
        case .chosenYear(let year): year
        case .week, .month, .all: nil
        }
    }
}
