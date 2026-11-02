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

@Test func backAndForwardStepThroughTheSources() {
    var history = SourceHistory(start: nil)
    history.visit(.timeline)
    history.visit(.timeline)
    history.visit(.playlist(1))
    #expect(history.back() == .some(.timeline))
    #expect(history.back() == .some(nil))
    #expect(history.back() == nil)
    #expect(history.forward() == .some(.timeline))
    history.visit(.history)
    #expect(!history.canGoForward)
    #expect(history.back() == .some(.timeline))
}

@Test func forgettingASourceKeepsThePlaceAndDropsRepeats() {
    var history = SourceHistory(start: nil)
    history.visit(.playlist(1))
    history.visit(nil)
    history.visit(.playlist(2))
    history.remove { $0 == .playlist(1) }
    #expect(history.back() == .some(nil))
    #expect(history.back() == nil)
    #expect(history.forward() == .some(.playlist(2)))
}
