import Foundation
import Library
import Settings

// How Listening Stats writes its numbers and spans, in the panel, Year in Review and the
// command line alike.

/// "about 82 hours", "about 40 minutes": a total of track lengths, which is approximate since a
/// play counts once most of a track was heard.
func approximateDuration(_ seconds: Double) -> String {
    seconds >= 3600
        ? "about " + count(Int((seconds / 3600).rounded()), "hour")
        : "about " + count(Int((seconds / 60).rounded()), "minute")
}

/// A list row's hours: "12.5 h", or minutes under an hour.
func hoursValue(_ seconds: Double) -> String {
    seconds >= 3600
        ? String(format: "%.1f h", seconds / 3600) : "\(Int((seconds / 60).rounded())) min"
}

/// "42%", or "0.4%" below one percent, so a few plays don't read as none.
func percentText(_ share: Double) -> String {
    let percent = share * 100
    if percent > 0, percent < 1 { return String(format: "%.1f%%", percent) }
    return "\(Int(percent.rounded()))%"
}

/// What a bar covers, as its tooltip and the chart's labels say it: "Tue 3 Mar", "Week of
/// 2 Mar", "March 2026", "2024".
func barTitle(_ bar: StatsReport.Bar, unit: StatsReport.BarUnit, calendar: Calendar = .current)
    -> String
{
    let format = DateFormatter()
    format.calendar = calendar
    format.timeZone = calendar.timeZone
    let start = Date(timeIntervalSince1970: TimeInterval(bar.span.start))
    switch unit {
    case .day: format.setLocalizedDateFormatFromTemplate("EEE d MMM")
    case .week: format.setLocalizedDateFormatFromTemplate("d MMM")
    case .month: format.setLocalizedDateFormatFromTemplate("MMMM yyyy")
    case .year: format.setLocalizedDateFormatFromTemplate("yyyy")
    }
    let text = format.string(from: start)
    return unit == .week ? "Week of \(text)" : text
}

/// What the chart's title calls its bars.
func barsTitle(_ unit: StatsReport.BarUnit) -> String {
    switch unit {
    case .day: "Plays per Day"
    case .week: "Plays per Week"
    case .month: "Plays per Month"
    case .year: "Plays per Year"
    }
}

/// "Saturday 14 June 2025", for the busiest day.
func dayTitle(_ span: PlaySpan, calendar: Calendar = .current) -> String {
    let format = DateFormatter()
    format.calendar = calendar
    format.timeZone = calendar.timeZone
    format.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
    return format.string(from: Date(timeIntervalSince1970: TimeInterval(span.start)))
}

/// "14 Jun 2025", for when something was first played.
func shortDate(_ seconds: Int64, calendar: Calendar = .current) -> String {
    let format = DateFormatter()
    format.calendar = calendar
    format.timeZone = calendar.timeZone
    format.dateStyle = .medium
    format.timeStyle = .none
    return format.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

/// The period's report as JSON for the command line: `{"period": "month", "report": {…}}`.
func statsJSON(_ report: StatsReport, period: StatsPeriod) throws -> String {
    struct Output: Encodable {
        var period: String
        var report: StatsReport
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(
        decoding: try encoder.encode(Output(period: period.text, report: report)), as: UTF8.self)
}

/// What the period's report says, for the command line: its totals, then each top list.
func statsSummary(_ report: StatsReport, period: StatsPeriod, ranking: StatsReport.Ranking)
    -> String
{
    var lines = [
        period.title + (report.span.map { " (\($0.title()))" } ?? ""),
        count(report.plays, "play") + ", " + approximateDuration(report.seconds),
        [
            tracks(report.tracks), count(report.artists, "artist"), count(report.albums, "album"),
            percentText(report.libraryShare) + " of the library",
        ].joined(separator: ", "),
    ]
    if report.missingPlays > 0 {
        lines.append(count(report.missingPlays, "play") + " " + missingText.lowercased())
    }
    if report.undatedPlays > 0 {
        lines.append("+" + count(report.undatedPlays, "imported play") + " without dates")
    }
    for list in StatsReport.List.allCases {
        let entries = report.list(list, by: ranking).prefix(10)
        guard !entries.isEmpty else { continue }
        lines.append("")
        lines.append(list.title + (ranking == .hours ? " by Hours" : ""))
        for (place, entry) in entries.enumerated() {
            let value = ranking == .plays ? count(entry.plays, "play") : hoursValue(entry.seconds)
            let detail = entry.detail.map { " – " + $0 } ?? ""
            lines.append("  \(place + 1). \(entry.name)\(detail) (\(value))")
        }
    }
    return lines.joined(separator: "\n")
}
