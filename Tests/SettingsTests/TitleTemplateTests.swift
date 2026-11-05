import Foundation
import Testing

@testable import Settings

private let setting = AppSettings().windowTitle

@Test func theDefaultIsTheTitleAndTheArtist() {
    #expect(setting.defaultValue == TitleTemplate.windowTitle)
    #expect(
        TitleTemplate.windowTitle.parts == [.token(.title), .text(" — "), .token(.artist)])
    #expect(TitleTemplate.windowTitle.problem() == nil)
}

@Test func textAndTokensSplitInOrder() {
    #expect(
        TitleTemplate("♪ {albumArtist}: {album} ({year})").parts == [
            .text("♪ "), .token(.albumArtist), .text(": "), .token(.album), .text(" ("),
            .token(.year), .text(")"),
        ])
    #expect(TitleTemplate("{trackNumber}{title}").parts == [.token(.trackNumber), .token(.title)])
    #expect(TitleTemplate("Plain").parts == [.text("Plain")])
}

/// Braces hold only a token, so anything else in them, or a brace alone, is refused by name,
/// with every token in the message.
@Test(arguments: [
    ("{title} — {artsit}", "no token {artsit}"), ("{}", "no token {}"),
    ("{Title}", "no token {Title}"), ("{title", "a { with no } after it"),
    ("title}", "a } with no { before it"), ("{ti{tle}", "no token {ti{tle}"),
    ("{title}} by {artist}", "a } with no { before it"),
    ("{\u{301}title}", "no token {\u{301}title}"),
    ("{title} }\u{301}", "a } with no { before it"),
])
func aTemplateWithAProblemIsRefused(_ template: String, _ problem: String) throws {
    let title = TitleTemplate(template)
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

/// Fields fill in as they are, punctuation at their ends included; the text before an empty
/// field goes with it, and at either end of the line the text after it too.
private let fills: [(String, [String: String], String)] = [
    ("{title} — {artist}", ["title": "Hold On,"], "Hold On,"),
    ("{title}", ["title": "Intro:"], "Intro:"),
    ("{title} — {artist}", ["title": "Kid A /", "artist": "Radiohead"], "Kid A / — Radiohead"),
    ("{title}", ["title": "-"], "-"),
    ("{title} — {artist} — {album}", ["title": "T", "album": "Album"], "T — Album"),
    ("{title} — {artist} — {album}", ["artist": "A", "album": "Album"], "A — Album"),
    ("{title} — {artist} — {album}", ["title": "T", "artist": "A"], "T — A"),
    ("{title} | {artist} / {album} · {year}", ["title": "T", "year": "1969"], "T · 1969"),
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
    // Swinsian's line: the word before a field is the field's.
    ("{title} by {artist} from {album}", ["title": "Song", "album": "Album"], "Song from Album"),
    ("{title} by {artist} from {album}", ["title": "Song", "artist": "Artist"], "Song by Artist"),
    ("{title} by {artist} from {album}", ["title": "Song"], "Song"),
    ("{title} by {artist} from {album}", ["artist": "A", "album": "Album"], "A from Album"),
    ("{title} by {artist} from {album}", [:], ""),
    ("{artist} - {title}", ["title": "Song"], "Song"),
    ("[{artist}] {title} ({album})", ["artist": "A"], "[A]"),
    ("[{artist} {album}] {title}", ["artist": "A"], "[A]"),
    // Blank is empty, and the line is trimmed.
    (
        "{title} by {artist} from {album}", ["title": "Song", "artist": " \n", "album": "\t"],
        "Song"
    ),
    ("\n{title}\n", ["title": "Song"], "Song"), ("  {artist} — {title}  ", ["title": "T"], "T"),
    // A doubled brace is a brace.
    ("{{{title}}}", ["title": "Song"], "{Song}"), ("{{x}} {title}", ["title": "Song"], "{x} Song"),
    ("{title}\u{301}x", ["title": "Song"], "Song\u{301}x"),
]

@Test(arguments: fills)
func aTemplateFillsFieldsAsTheyAre(
    _ template: String, _ values: [String: String], _ expected: String
) {
    let title = TitleTemplate(template)
    #expect(title.problem() == nil)
    #expect(title.fill { values[$0.rawValue] } == expected)
}

@Test(arguments: ["", " ", "\n\t"])
func anEmptyTemplateIsRefused(_ template: String) throws {
    let found = try #require(TitleTemplate(template).problem())
    #expect(found.hasPrefix("empty"))
    guard case .failure(.invalid(let reason)) = setting.decode(json: template) else {
        Issue.record("accepted an empty template")
        return
    }
    #expect(reason == found)
}

/// The toolbar's Title Line holds a template too, Swinsian's line by default.
@Test func theTitleLineIsATemplate() throws {
    let titleLine = AppSettings().headerTitleFormat
    #expect(titleLine.defaultValue == TitleTemplate.titleLine)
    #expect(
        TitleTemplate.titleLine.fill {
            ["title": "FI3AC2384210", "artist": "Aleksi Perälä", "album": "Alithia E'"][$0.rawValue]
        } == "FI3AC2384210 by Aleksi Perälä from Alithia E'")
    guard case .failure(.invalid) = titleLine.decode(json: "{title} on {decade}") else {
        Issue.record("accepted an unknown token")
        return
    }
    #expect(titleLine.kind == setting.kind)
}

@Test func theTemplateIsAStringInTheFile() throws {
    let data = try JSONEncoder().encode(TitleTemplate("{album} by {artist}"))
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
