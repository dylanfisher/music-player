import Testing

@testable import DisplayText

@Test func everyWordMustBeInOneOfTheTexts() {
    let texts = ["Björk - Homogenic (1997)", "FLAC", "Imported"]
    #expect(ListFilter("bjork").matches(texts), "accents and case ignored")
    #expect(ListFilter("homogenic flac").matches(texts), "words in different texts")
    #expect(ListFilter("  1997\tIMPORTED ").matches(texts))
    #expect(!ListFilter("homogenic mp3").matches(texts), "every word, not any")
    #expect(!ListFilter("flacimported").matches(texts), "a word can't span two texts")
}

@Test func anEmptyFilterPassesEveryRow() {
    #expect(ListFilter("").isEmpty)
    #expect(ListFilter(" \t").isEmpty)
    #expect(ListFilter(" ").matches([]))
    #expect(!ListFilter("a").isEmpty)
}
