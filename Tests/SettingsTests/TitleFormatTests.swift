import Testing

@testable import Settings

private let schema = AppSettings()

private func parsed(_ text: String) throws(ConfigErrorList) -> ConfigContents {
    try ConfigFile.parse(
        ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
        conflicts: schema.conflicts)
}

private let track: [TitleFormat.Field: String] = [
    .title: "FI3AC2384210", .artist: "Aleksi Perälä", .album: "Alithia E'",
]

/// `format`'s line for a track with `values`.
private func line(_ format: String, _ values: [TitleFormat.Field: String]) -> String {
    TitleFormat(format).line { values[$0] }
}

@Test func theDefaultIsSwinsiansLine() {
    #expect(schema.headerTitleFormat.defaultValue.text == "{title} by {artist} from {album}")
    #expect(
        schema.headerTitleFormat.defaultValue.line { track[$0] }
            == "FI3AC2384210 by Aleksi Perälä from Alithia E'")
}

/// An empty field takes the text before it along, and at either end of the line the text after
/// it too, so nothing is left hanging.
@Test func anEmptyFieldLeavesNoTextHanging() {
    let swinsian = "{title} by {artist} from {album}"
    #expect(line(swinsian, [.title: "Song", .album: "Album"]) == "Song from Album")
    #expect(line(swinsian, [.title: "Song", .artist: "Artist"]) == "Song by Artist")
    #expect(line(swinsian, [.title: "Song"]) == "Song")
    #expect(line(swinsian, [.artist: "Artist", .album: "Album"]) == "Artist from Album")
    #expect(line(swinsian, [:]) == "")
    #expect(line("{artist} - {title}", [.title: "Song"]) == "Song")
    #expect(line("{title} ({album})", [.title: "Song"]) == "Song")
    #expect(line("({album}) {title}", [.title: "Song"]) == "Song")
    #expect(line("({album}) {title}", [.title: "Song", .album: "Album"]) == "(Album) Song")
    #expect(line("  {artist} — {title}  ", track) == "Aleksi Perälä — FI3AC2384210")
    #expect(line("plain", [:]) == "plain")
}

/// Blank is empty, newlines included, and the line is trimmed of them too.
@Test func whitespaceAndNewlinesAreEmpty() {
    let swinsian = "{title} by {artist} from {album}"
    #expect(line(swinsian, [.title: "Song", .artist: " \n", .album: "\t"]) == "Song")
    #expect(line("\n{title}\n", [.title: "Song"]) == "Song")
}

@Test func anUnknownFieldOrAnOpenBraceIsAProblem() throws {
    #expect(
        TitleFormat("{title} on {year}").problem()
            == "{year} isn't a field; the fields are {title}, {artist}, {album}")
    #expect(TitleFormat("{Title}").problem() != nil)
    #expect(TitleFormat("{title").problem() == "a { isn't closed with a }; write {{ for a brace")
    let values = try parsed(#"{"appearance.headerTitleFormat": "{artist}: {title}"}"#).values
    #expect(
        (values["appearance.headerTitleFormat"] as? TitleFormat)?.line { track[$0] }
            == "Aleksi Perälä: FI3AC2384210")
    for text in ["{title} {genre}", "{", "{}"] {
        #expect(throws: ConfigErrorList.self, "\(text)") {
            try parsed(#"{"appearance.headerTitleFormat": "\#(text)"}"#)
        }
    }
    #expect(throws: ConfigErrorList.self) { try parsed(#"{"appearance.headerTitleFormat": 1}"#) }
}

/// A doubled brace is a brace, and a lone one is a problem either way round. A brace stays one
/// with a combining mark after it, which would make it part of one Character.
@Test func doubledBracesAreBracesAndALoneOneIsAProblem() {
    #expect(line("{{{title}}}", [.title: "Song"]) == "{Song}")
    #expect(line("{{{title}}} by {artist}", [.title: "Song", .artist: "A"]) == "{Song} by A")
    #expect(line("{{x}} {title}", [.title: "Song"]) == "{x} Song")
    #expect(
        TitleFormat("{title}} by {artist}").problem()
            == "a } has no { before it; write }} for a brace")
    #expect(TitleFormat("} {title}").problem() != nil)
    #expect(
        TitleFormat("{\u{301}title}").problem()?.hasPrefix("{\u{301}title} isn't a field") == true)
    #expect(TitleFormat("{title}\u{301}").problem() == nil)
    #expect(line("{title}\u{301}x", [.title: "Song"]) == "Song\u{301}x")
    #expect(TitleFormat("{title} }\u{301}").problem() != nil)
}
