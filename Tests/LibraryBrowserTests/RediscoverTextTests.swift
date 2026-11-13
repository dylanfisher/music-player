import Foundation
import Testing

@testable import LibraryBrowser
@testable import Recommender

@Test func theDayIsNamedAsADate() {
    let locale = Locale(identifier: "en_US")
    #expect(rediscoverDayTitle("2026-11-12", locale: locale) == "Thursday, November 12")
    #expect(rediscoverDayTitle("someday", locale: locale) == "someday")
}

@Test func eachThreadNamesWhatItsAlbumsShareAndTheirTitles() {
    var day = rediscoverDay(["a1", "a2", "a3"])
    #expect(rediscoverThreadsText(day) == "No two of today's albums share anything.")
    day.threads = [
        RediscoverDay.Thread(
            kind: .label, words: "Seed Records, 1995 to 2001", ids: ["ka1", "ka3"], artist: nil,
            label: RediscoverDay.Named(id: 30, name: "Seed Records")),
        RediscoverDay.Thread(
            kind: .credit, words: "Dee Engineer\u{1B}[31m", ids: ["ka2", "gone"], artist: nil,
            label: nil),
    ]
    #expect(
        rediscoverThreadsText(day)
            == "Seed Records, 1995 to 2001: Album a1, Album a3\nDee Engineer\\u{1B}[31m: Album a2")
}

@Test func anAlbumsReasonsAreALineEach() {
    var album = rediscovered("a1")
    album.reasons.append(
        RediscoverDay.Reason(
            kind: .credit, words: "Engineer: Dee Engineer, also on 2 albums you played",
            keys: ["a9"], artist: nil, role: "Engineer", label: nil))
    #expect(
        rediscoverReasonsText(album)
            == "Made-Up Artist – Album a1\n• Never played\n"
            + "• Engineer: Dee Engineer, also on 2 albums you played")
}
