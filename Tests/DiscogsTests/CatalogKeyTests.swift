import Testing

@testable import Discogs

@Test func theFoldIsTheCoverageCountsRules() {
    #expect(CatalogKey.fold("The Persuader") == "persuader")
    #expect(CatalogKey.fold("Mr. James Barth & A.D.") == "mrjamesbarthandad")
    #expect(CatalogKey.fold("Soleil (2)") == "soleil")
    #expect(CatalogKey.fold("Jesper Dahlbäck") == "jesperdahlback")
    #expect(CatalogKey.fold("  Sigur Rós  ") == "sigurros")
    // Only a leading "The", and only with a word after it.
    #expect(CatalogKey.fold("Into The Void") == "intothevoid")
    #expect(CatalogKey.fold("The") == "the")
    #expect(CatalogKey.fold("佐瑟溫克") == "佐瑟溫克")
}

@Test func aTitleLosesItsEditionWordsInBrackets() {
    #expect(CatalogKey.fold("Stockholm (Remastered)", title: true) == "stockholm")
    #expect(
        CatalogKey.fold("Selected Ambient Works [Deluxe Edition]", title: true)
            == "selectedambientworks")
    #expect(CatalogKey.fold("Kind of Blue (SACD)", title: true) == "kindofblue")
    #expect(CatalogKey.fold("Album (2009 Remaster)", title: true) == "album")
    #expect(CatalogKey.fold("Live (Disc 2)", title: true) == "live")
    // A bracket that names the album, not an edition, stays.
    #expect(CatalogKey.fold("Untitled (Black)", title: true) == "untitledblack")
    // An artist's name keeps its brackets but the suffix.
    #expect(CatalogKey.fold("Album (Remastered)") == "albumremastered")
}

@Test func aCreditOfSeveralArtistsHasAKeyForEachAndForAllTogether() {
    #expect(
        CatalogKey.artistKeys(["Simon", "Garfunkel"]) == [
            "simon", "garfunkel", "simongarfunkel", "simonandgarfunkel",
        ])
    #expect(CatalogKey.artistKeys(["The Persuader"]) == ["persuader"])
    #expect(CatalogKey.artistKeys(["", "!!!"]) == [])
}

@Test func barcodesAndCatalogNumbersFoldToTheirLettersAndDigits() {
    #expect(CatalogKey.barcode("0 7464-63628-2 2") == CatalogKey.barcode("074646362822"))
    #expect(CatalogKey.catalogNumber("SK 026") == "sk026")
    #expect(CatalogKey.catalogNumber("none") == nil)
    #expect(CatalogKey.barcode("None") == "")
    #expect(CatalogKey.catalogNumber(" - ") == nil)
}

@Test func aTitleIsAlsoTriedWithoutALeadingCatalogNumberOrTrailingEditionWords() {
    #expect(CatalogKey.titleVariants("[SK 032] Stockholm") == ["Stockholm"])
    #expect(CatalogKey.titleVariants("Stockholm - 2011 Remaster") == ["Stockholm"])
    #expect(CatalogKey.titleVariants("Live – Deluxe Edition") == ["Live"])
    #expect(CatalogKey.titleVariants("Stockholm") == [])
    // A dash that isn't before edition words is part of the title.
    #expect(CatalogKey.titleVariants("Side A - Side B") == [])
    #expect(CatalogKey.titleVariants("[SK 032]") == [])
}

@Test func aTitleIsAlsoTriedWithoutTheLabelInfoAndFormatWordsALibraryAddsToIt() {
    #expect(CatalogKey.titleVariants("Ghost [WIGCD 32]") == ["Ghost"])
    #expect(CatalogKey.titleVariants("Funf (OSTGUTCD15)") == ["Funf"])
    #expect(CatalogKey.titleVariants("Absorb WEB") == ["Absorb"])
    #expect(CatalogKey.titleVariants("Live In South Beach CD2") == ["Live In South Beach"])
    #expect(CatalogKey.titleVariants("Arctic Night [EP]") == ["Arctic Night"])
    // "(2014)" folds away already, as Discogs's "(2)" does; a square bracket didn't.
    #expect(CatalogKey.titleVariants("Louis Armstrong [1930]") == ["Louis Armstrong"])
    // A step at a time, each a spelling: the format word, then the leading number.
    #expect(
        CatalogKey.titleVariants("(CURLE 024) Talis / Into The Red WEB")
            == ["(CURLE 024) Talis / Into The Red", "Talis / Into The Red"])
    #expect(
        CatalogKey.titleVariants("Fabric 53-(Fabric105D)-WEB")
            == ["Fabric 53-(Fabric105D)", "Fabric 53"])
    // The artist's name before a dash, after a leading catalog number.
    #expect(
        CatalogKey.titleVariants("[did034] - Zzzzra & Axs - Ala Ned Rex", artist: "Zzzzra & Axs")
            == ["Zzzzra & Axs - Ala Ned Rex", "Ala Ned Rex"])
    #expect(CatalogKey.titleVariants("VA - Kompakt Total 12", artist: nil) == ["Kompakt Total 12"])
    // Brackets of words with no digit are the title's own.
    #expect(CatalogKey.titleVariants("Altogether Lost (The Remixes)") == [])
    #expect(CatalogKey.titleVariants("Side A - Side B", artist: "Side C") == [])
}

@Test func aTitleNamesTheCatalogNumberInItsBrackets() {
    #expect(CatalogKey.catalogNumbers(inTitle: "Ghost [WIGCD 32]") == ["WIGCD 32"])
    #expect(CatalogKey.catalogNumbers(inTitle: "(ACRE 021) Evelyn EP WEB") == ["ACRE 021"])
    #expect(
        CatalogKey.catalogNumbers(inTitle: "Snake at Number 2 (APNEA027-WEB)")
            == ["APNEA027-WEB", "APNEA027"])
    // A year, a disc or format words aren't numbers, nor is a bracket of words.
    #expect(CatalogKey.catalogNumbers(inTitle: "Phoenix (2014)") == [])
    #expect(CatalogKey.catalogNumbers(inTitle: "10 Years (Disc 1)") == [])
    #expect(CatalogKey.catalogNumbers(inTitle: "Arctic Night [EP]") == [])
    #expect(CatalogKey.catalogNumbers(inTitle: "Altogether Lost (The Remixes)") == [])
}

@Test func titlesThatSayLittleArentDistinctive() {
    #expect(TitleDistinctness.share(["Östermalm", "Gamla Stan", "Kungsholmen"]) == 1)
    #expect(TitleDistinctness.share(["Untitled 1", "Untitled 2", "Track 03", "A4"]) == 0)
    // The same title but for a number tells no track apart, nor does a Roman numeral.
    #expect(TitleDistinctness.share(["Ghost 1", "Ghost 2", "Part II", "Sun"]) == 0.25)
    #expect(TitleDistinctness.share([nil, "", "Ok"]) == 0)
    #expect(TitleDistinctness.share([]) == 0)
}

@Test func theMatchKeyFoldsMarksOutsideTheLatinTableAsTheLibraryTaggerAlwaysDid() {
    // The service keeps these marks; the player re-checks at auto-tag (ADR 0148), so the golden
    // cases leave them out and this is the player's side of that difference.
    #expect(CatalogKey.matchKey("Việt") == CatalogKey.matchKey("Viet"))
    #expect(CatalogKey.matchKey("Việt") == "viet")
    #expect(CatalogKey.matchKey("Ænima") == CatalogKey.matchKey("Aenima"))
}

@Test func titlesDifferingOnlyInCaseScoreOneInAnyScript() {
    #expect(TitleSimilarity(["Кино"]).similarities(to: "кино") == [1])
    #expect(TitleSimilarity(["ΔΕΛΤΑ"]).similarities(to: "δελτα") == [1])
    #expect(TitleSimilarity(["Việt"]).similarities(to: "Viet") == [1])
}
