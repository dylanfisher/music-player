import DisplayText
import Foundation
import Recommender

/// The day asked for in words, "Thursday, November 12", or as the service gave it when it
/// isn't a date.
func rediscoverDayTitle(_ day: String, locale: Locale = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
        let date = calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else { return terminalSafe(day) }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
    return formatter.string(from: date)
}

/// What the day was drawn from: "24 albums of 6,541, scored Nov 11, 2026 at 3:00 AM".
func rediscoverFactsText(_ day: RediscoverDay) -> String {
    let scored = DateFormatter.localizedString(
        from: Date(timeIntervalSince1970: TimeInterval(day.facts.computedAt)), dateStyle: .medium,
        timeStyle: .short)
    return "\(count(day.albums.count, "album")) of \(number(day.facts.albumsConsidered)),"
        + " scored \(scored)"
}

/// The day's threads, a line each: what its albums share, and their titles.
func rediscoverThreadsText(_ day: RediscoverDay) -> String {
    guard !day.threads.isEmpty else { return "No two of today's albums share anything." }
    let titles = Dictionary(
        day.albums.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    return day.threads.map { thread in
        let albums = thread.ids.compactMap { titles[$0] }.joined(separator: ", ")
        return terminalSafe("\(thread.words): \(albums)")
    }.joined(separator: "\n")
}

/// The selected album and why it's among the day's, a reason a line.
func rediscoverReasonsText(_ album: RediscoverDay.Album) -> String {
    ([terminalSafe("\(album.artist) – \(album.title)")]
        + album.reasons.map { "• " + terminalSafe($0.words) }).joined(separator: "\n")
}

/// What the panel says in place of the day, or beside it.
func rediscoverProblemText(_ problem: RediscoverModel.Problem) -> String {
    switch problem {
    case .notSet: return serviceNotSetText
    case .failed(let text): return terminalSafe(text)
    case .unknownAlbums(let unknown):
        return "\(count(unknown, "album")) of the day aren't in this library, though its"
            + " profile was sent again. Refresh in a minute; if they stay, the service may"
            + " be keeping another Mac's profile."
    case .refused(let refusal):
        switch refusal.code {
        case .noProfile:
            return "The service has no library profile yet, and sending it failed. Send"
                + " Library Profile to Service, then Refresh."
        default: return "\(refusal)"
        }
    }
}
