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

@Test func theDefaultIsSwinsiansLine() {
    #expect(schema.headerTitleFormat.defaultValue.text == "{title} by {artist} from {album}")
    #expect(
        schema.headerTitleFormat.defaultValue.line(track)
            == "FI3AC2384210 by Aleksi Perälä from Alithia E'")
}

/// An empty field takes the text just before it along, so no "by" or "from" is left hanging.
@Test func anEmptyFieldGoesWithTheTextBeforeIt() {
    let format = TitleFormat.defaultHeaderTitle
    #expect(format.line([.title: "Song", .album: "Album"]) == "Song from Album")
    #expect(format.line([.title: "Song", .artist: "Artist", .album: " "]) == "Song by Artist")
    #expect(format.line([.title: "Song"]) == "Song")
    #expect(format.line([:]) == "")
    // Only the text just before: the title has none, and the text after the last field stays.
    #expect(format.line([.artist: "Artist"]) == "by Artist")
    #expect(TitleFormat("{title} ({album}) ").line([.title: "Song"]) == "Song)")
    #expect(TitleFormat("  {artist} — {title}  ").line(track) == "Aleksi Perälä — FI3AC2384210")
    #expect(TitleFormat("Now: {title}").line([:]) == "")
    #expect(TitleFormat("plain").line([:]) == "plain")
}

@Test func anUnknownFieldOrAnOpenBraceIsAProblem() throws {
    #expect(
        TitleFormat("{title} on {year}").problem()
            == "{year} isn't a field; the fields are {title}, {artist}, {album}")
    #expect(TitleFormat("{Title}").problem() != nil)
    #expect(TitleFormat("{title").problem() == "a { isn't closed with a }")
    #expect(TitleFormat("{title}} by {artist}").problem() == nil)
    let values = try parsed(#"{"appearance.headerTitleFormat": "{artist}: {title}"}"#).values
    #expect(
        (values["appearance.headerTitleFormat"] as? TitleFormat)?.line(track)
            == "Aleksi Perälä: FI3AC2384210")
    for text in ["{title} {genre}", "{", "{}"] {
        #expect(throws: ConfigErrorList.self, "\(text)") {
            try parsed(#"{"appearance.headerTitleFormat": "\#(text)"}"#)
        }
    }
    #expect(throws: ConfigErrorList.self) { try parsed(#"{"appearance.headerTitleFormat": 1}"#) }
}
