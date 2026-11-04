import Foundation
import Testing

@testable import Settings

private let setting = AppSettings().windowTitle

@Test func theDefaultIsTheTitleAndTheArtist() {
    #expect(setting.defaultValue == WindowTitle.default)
    #expect(
        WindowTitle.default.parts == [.token(.title), .text(" — "), .token(.artist)])
    #expect(WindowTitle.default.problem() == nil)
}

@Test func textAndTokensSplitInOrder() {
    #expect(
        WindowTitle("♪ {albumArtist}: {album} ({year})").parts == [
            .text("♪ "), .token(.albumArtist), .text(": "), .token(.album), .text(" ("),
            .token(.year), .text(")"),
        ])
    #expect(WindowTitle("{trackNumber}{title}").parts == [.token(.trackNumber), .token(.title)])
    #expect(WindowTitle("Plain").parts == [.text("Plain")])
}

/// Braces hold only a token, so anything else in them, or a brace alone, is refused by name,
/// with every token in the message.
@Test(arguments: [
    ("{title} — {artsit}", "no token {artsit}"), ("{}", "no token {}"),
    ("{Title}", "no token {Title}"), ("{title", "a { with no } after it"),
    ("title}", "a } with no { before it"), ("{ti{tle}", "no token {ti{tle}"),
])
func aTemplateWithAProblemIsRefused(_ template: String, _ problem: String) throws {
    let title = WindowTitle(template)
    let found = try #require(title.problem())
    #expect(found.hasPrefix(problem), "\(found)")
    #expect(title.parts.isEmpty)
    if problem.hasPrefix("no token") {
        for token in TitleToken.allCases { #expect(found.contains(token.placeholder)) }
    }
    guard case .failure(.invalid(let reason)) = setting.decode(json: template) else {
        Issue.record("accepted \(template)")
        return
    }
    #expect(reason == found)
}

/// Fields fill in as they are, punctuation at their ends included; text beside an empty field
/// goes, keeping one separator between the fields that have values.
private let fills: [(String, [String: String], String)] = [
    ("{title} — {artist}", ["title": "Hold On,"], "Hold On,"),
    ("{title}", ["title": "Intro:"], "Intro:"),
    ("{title} — {artist}", ["title": "Kid A /", "artist": "Radiohead"], "Kid A / — Radiohead"),
    ("{title}", ["title": "-"], "-"),
    ("{title} — {artist} — {album}", ["title": "T", "album": "Album"], "T — Album"),
    ("{title} — {artist} — {album}", ["artist": "A", "album": "Album"], "A — Album"),
    ("{title} — {artist} — {album}", ["title": "T", "artist": "A"], "T — A"),
    ("{title} | {artist} / {album} · {year}", ["title": "T", "year": "1969"], "T | 1969"),
    ("{artist} ({year})", ["artist": "A"], "A"),
    ("{artist} ({year})", ["artist": "A", "year": "1969"], "A (1969)"),
    ("♪ {title}", ["title": "T"], "♪ T"), ("♪ {title}", [:], ""),
    ("Now: {album}!", ["album": "B"], "Now: B!"), ("Plain", [:], "Plain"),
    // Brackets around empty fields go whole, with the space before them.
    ("{artist} ({year}) {album}", ["artist": "A", "album": "Album"], "A Album"),
    (
        "{artist} ({year}) {album}", ["artist": "A", "year": "1969", "album": "Album"],
        "A (1969) Album"
    ),
    (
        "{album} - {artist} ({year}) {genre}", ["album": "A", "artist": "B", "genre": "D"],
        "A - B D"
    ),
    ("{title} ({year})", ["title": "T"], "T"), ("({year}) {title}", ["title": "T"], "T"),
    ("[{year}] {title}", ["year": "1969", "title": "T"], "[1969] T"),
    ("{title} ({year}) [{genre}]", ["title": "T", "genre": "Rock"], "T [Rock]"),
    ("{title} ({year}) [{genre}]", ["title": "T"], "T"),
    ("{title} [{album} ({year})]", ["title": "T", "album": "B"], "T [B]"),
    ("{title} [{album} ({year})]", ["title": "T"], "T"),
    ("{title} (live)", ["title": "T"], "T (live)"),
    ("{title} ({artist}", ["title": "T"], "T"), ("{title}) {artist}", ["title": "T"], "T"),
]

@Test(arguments: fills)
func aTemplateFillsFieldsAsTheyAre(
    _ template: String, _ values: [String: String], _ expected: String
) {
    let title = WindowTitle(template)
    #expect(title.problem() == nil)
    #expect(title.fill { values[$0.rawValue] } == expected)
}

@Test func anEmptyTemplateIsRefused() throws {
    let found = try #require(WindowTitle("").problem())
    #expect(found.hasPrefix("empty"))
    guard case .failure(.invalid(let reason)) = setting.decode(json: "") else {
        Issue.record("accepted an empty template")
        return
    }
    #expect(reason == found)
}

@Test func theTemplateIsAStringInTheFile() throws {
    let data = try JSONEncoder().encode(WindowTitle("{album} by {artist}"))
    #expect(String(data: data, encoding: .utf8) == #""{album} by {artist}""#)
    guard case .success(let title) = setting.decode(json: "{genre}") else {
        Issue.record("refused {genre}")
        return
    }
    #expect(title.parts == [.token(.genre)])
    guard case .failure(.wrongType) = setting.decode(json: 3) else {
        Issue.record("accepted a number")
        return
    }
}

/// The settings window lists every token with what it stands for.
@Test func theKindCarriesEveryTokenAndItsHelp() {
    guard case .template(let tokens) = setting.kind else {
        Issue.record("\(setting.kind)")
        return
    }
    #expect(tokens.map(\.name) == TitleToken.allCases.map { "{\($0.rawValue)}" })
    #expect(tokens.map(\.help) == TitleToken.allCases.map(\.help))
    #expect(Set(tokens.map(\.help)).count == tokens.count)
}
