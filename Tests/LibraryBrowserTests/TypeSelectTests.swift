import Settings
import Testing

@testable import LibraryBrowser

private final class Clock {
    var seconds = 100.0
}

@Test func aPauseStartsANewQuery() {
    let clock = Clock()
    var select = TypeSelect(now: { clock.seconds })
    #expect(select.add("b") == "b")
    clock.seconds += 0.5
    #expect(select.add("e") == "be")
    #expect(select.isTyping)
    clock.seconds += TypeSelect.resetSeconds
    #expect(!select.isTyping)
    #expect(select.add("c") == "c")
    select.reset()
    #expect(select.add("r") == "r")
    #expect(select.add("r") == "rr")
}

@Test func theFirstRowStartingWithTheQueryWinsIgnoringCaseAndAccents() {
    let names = ["Abba", "Résumé", "rr-notes", "Radiohead", "resume"]
    #expect(TypeSelect.firstIndex(startingWith: "re", in: names) == 1)
    #expect(TypeSelect.firstIndex(startingWith: "RA", in: names) == 3)
    #expect(TypeSelect.firstIndex(startingWith: "rr", in: names) == 2)
    #expect(TypeSelect.firstIndex(startingWith: "z", in: names) == nil)
}
