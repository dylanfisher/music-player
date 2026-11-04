import Testing

@testable import Settings

private let schema = AppSettings()

private func parsed(_ text: String) throws(ConfigErrorList) -> ConfigContents {
    try ConfigFile.parse(
        ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
        conflicts: schema.conflicts)
}

@Test func theLineColorsAreTheSystemsAndAlbumLinesAreOffByDefault() {
    #expect(schema.rowLineColor.defaultValue == nil)
    #expect(schema.albumLineColor.defaultValue == nil)
    #expect(schema.albumLines.defaultValue == false)
}

@Test func aColorIsSixOrEightHexDigits() throws {
    let opaque = try #require(HexColor("#ff8000").components)
    #expect(opaque.red == 1 && opaque.green == Double(0x80) / 255 && opaque.blue == 0)
    #expect(opaque.alpha == 1)
    #expect(HexColor("#00000080").components?.alpha == Double(0x80) / 255)
    for text in ["", "#", "ff8000", "#ff800", "#ff8000801", "#gg8000", "#+f8000", "red"] {
        #expect(HexColor(text).components == nil, "\(text)")
    }
}

@Test func aColorWritesItsComponentsAsEightDigits() {
    #expect(HexColor(red: 1, green: 0.5, blue: 0, alpha: 0.25).text == "#FF800040")
    #expect(HexColor(red: 2, green: -1, blue: 0.004, alpha: 1).text == "#FF0001FF")
    let round = HexColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
    #expect(HexColor(round.text) == round)
}

@Test func theConfigFileTakesColorsAndRefusesTheRest() throws {
    let values = try parsed(##"{"appearance.rowLineColor": "#11223344"}"##).values
    #expect((values[schema.rowLineColor.key] as? HexColor)?.text == "#11223344")
    #expect(
        try parsed(#"{"appearance.albumLineColor": null}"#).values[schema.albumLineColor.key] != nil
    )
    for text in [#""blue""#, ##""#1234""##, "12"] {
        #expect(throws: ConfigErrorList.self, "\(text)") {
            try parsed(##"{"appearance.albumLineColor": \##(text)}"##)
        }
    }
}
