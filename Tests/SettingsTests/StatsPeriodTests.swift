import Foundation
import Testing

@testable import Settings

/// A Gregorian calendar in Los Angeles.
private func losAngeles() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}

/// The seconds of a local time in `calendar`.
private func seconds(
    _ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
    _ minute: Int = 0
) -> Int64 {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    return Int64(calendar.date(from: components)!.timeIntervalSince1970)
}

private func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

@Test func thePeriodsAreTheLastDaysUpToToday() {
    let calendar = losAngeles()
    // Thursday 5 November 2026, 10:00.
    let now = date(seconds(calendar, 2026, 11, 5, 10))
    let tomorrow = seconds(calendar, 2026, 11, 6)
    #expect(
        StatsPeriod.week.span(now: now, calendar: calendar)
            == PlaySpan(start: seconds(calendar, 2026, 10, 30), end: tomorrow))
    #expect(
        StatsPeriod.month.span(now: now, calendar: calendar)
            == PlaySpan(start: seconds(calendar, 2026, 10, 7), end: tomorrow))
    #expect(
        StatsPeriod.year.span(now: now, calendar: calendar)
            == PlaySpan(start: seconds(calendar, 2025, 11, 6), end: tomorrow))
    #expect(
        StatsPeriod.chosenYear(2024).span(now: now, calendar: calendar)
            == PlaySpan(start: seconds(calendar, 2024, 1, 1), end: seconds(calendar, 2025, 1, 1)))
    #expect(StatsPeriod.all.span(now: now, calendar: calendar) == nil)
    #expect(StatsPeriod.week.title == "Past Week")
    #expect(StatsPeriod.year.reviewYear(now: now, calendar: calendar) == 2026)
    #expect(StatsPeriod.chosenYear(2024).reviewYear(now: now, calendar: calendar) == 2024)
    #expect(StatsPeriod.month.reviewYear(now: now, calendar: calendar) == nil)
}

@Test func aRollingPeriodCountsLocalDaysAcrossADaylightSavingChange() {
    let calendar = losAngeles()
    // Clocks went back at 2:00 on Sunday 1 November 2026, so that day had 25 hours.
    let now = date(seconds(calendar, 2026, 11, 3, 23, 59))
    let span = StatsPeriod.week.span(now: now, calendar: calendar)
    #expect(
        span
            == PlaySpan(start: seconds(calendar, 2026, 10, 28), end: seconds(calendar, 2026, 11, 4))
    )
    #expect(span.map { $0.end - $0.start } == Int64(7 * 86_400 + 3600))
}

@Test func aRollingPeriodCanCrossTheYearsEnd() {
    let calendar = losAngeles()
    let now = date(seconds(calendar, 2026, 1, 1, 0, 1))
    let span = StatsPeriod.week.span(now: now, calendar: calendar)
    #expect(
        span == PlaySpan(start: seconds(calendar, 2025, 12, 26), end: seconds(calendar, 2026, 1, 2))
    )
    // A minute before midnight on New Year's Eve is in the past week and in 2025, not 2026.
    let eve = seconds(calendar, 2025, 12, 31, 23, 59)
    #expect(span?.contains(eve) == true)
    #expect(StatsPeriod.chosenYear(2026).span(calendar: calendar)?.contains(eve) == false)
    #expect(StatsPeriod.chosenYear(2025).span(calendar: calendar)?.contains(eve) == true)
}

@Test func aPeriodReadsAsItIsWritten() {
    for period in [StatsPeriod.week, .month, .year, .chosenYear(2019), .all] {
        #expect(StatsPeriod(text: period.text) == period)
    }
    #expect(StatsPeriod(text: "Month") == .month)
    for text in ["", "weeks", "-2020", "20 20", "1899", "10000", "２０２０"] {
        #expect(StatsPeriod(text: text) == nil, "\(text)")
    }
}

@Test func aSpansTitleNamesItsDays() {
    let calendar = losAngeles()
    let day = PlaySpan(start: seconds(calendar, 2026, 3, 8), end: seconds(calendar, 2026, 3, 9))
    let week = PlaySpan(start: seconds(calendar, 2026, 3, 8), end: seconds(calendar, 2026, 3, 15))
    #expect(day.title(calendar: calendar).contains("8"))
    #expect(!day.title(calendar: calendar).contains("9"))
    #expect(week.title(calendar: calendar).contains("14"))
}
