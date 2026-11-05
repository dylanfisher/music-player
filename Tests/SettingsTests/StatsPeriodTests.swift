import Foundation
import Testing

@testable import Settings

/// A Gregorian calendar in Los Angeles whose weeks start on `firstWeekday`.
private func losAngeles(firstWeekday: Int = 1) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = firstWeekday
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

@Test func thePeriodsAreTheCalendarsAroundNow() {
    let calendar = losAngeles()
    // Thursday 5 November 2026, 10:00.
    let now = date(seconds(calendar, 2026, 11, 5, 10))
    #expect(
        StatsPeriod.week.span(now: now, calendar: calendar)
            == PlaySpan(start: seconds(calendar, 2026, 11, 1), end: seconds(calendar, 2026, 11, 8)))
    #expect(
        StatsPeriod.month.span(now: now, calendar: calendar)
            == PlaySpan(start: seconds(calendar, 2026, 11, 1), end: seconds(calendar, 2026, 12, 1)))
    #expect(
        StatsPeriod.year.span(now: now, calendar: calendar)
            == PlaySpan(start: seconds(calendar, 2026, 1, 1), end: seconds(calendar, 2027, 1, 1)))
    #expect(
        StatsPeriod.chosenYear(2024).span(now: now, calendar: calendar)
            == PlaySpan(start: seconds(calendar, 2024, 1, 1), end: seconds(calendar, 2025, 1, 1)))
    #expect(StatsPeriod.all.span(now: now, calendar: calendar) == nil)
    #expect(StatsPeriod.year.reviewYear(now: now, calendar: calendar) == 2026)
    #expect(StatsPeriod.chosenYear(2024).reviewYear(now: now, calendar: calendar) == 2024)
    #expect(StatsPeriod.month.reviewYear(now: now, calendar: calendar) == nil)
}

@Test func aWeekStartsOnTheSystemsFirstWeekday() {
    let monday = losAngeles(firstWeekday: 2)
    // Sunday 1 November is the last day of the week that started on Monday 26 October.
    let now = date(seconds(monday, 2026, 11, 1, 10))
    #expect(
        StatsPeriod.week.span(now: now, calendar: monday)
            == PlaySpan(start: seconds(monday, 2026, 10, 26), end: seconds(monday, 2026, 11, 2)))
}

@Test func aWeekCanCrossTheYearsEnd() {
    let calendar = losAngeles()
    let now = date(seconds(calendar, 2026, 1, 1, 0, 1))
    let span = StatsPeriod.week.span(now: now, calendar: calendar)
    #expect(
        span == PlaySpan(start: seconds(calendar, 2025, 12, 28), end: seconds(calendar, 2026, 1, 4))
    )
    // A minute before midnight on New Year's Eve is in last year, not this one.
    let eve = seconds(calendar, 2025, 12, 31, 23, 59)
    #expect(span?.contains(eve) == true)
    #expect(StatsPeriod.year.span(now: now, calendar: calendar)?.contains(eve) == false)
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
