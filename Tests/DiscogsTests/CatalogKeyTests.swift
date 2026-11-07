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
    #expect(CatalogKey.catalogNumber(" - ") == nil)
}
