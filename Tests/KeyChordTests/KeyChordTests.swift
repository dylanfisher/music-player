import AppKit
import Testing

@testable import KeyChord

@Test func storedSpellingRoundTrips() {
    let chords = [
        KeyChord("k", [.command, .shift]), KeyChord("+", .command), KeyChord(.function(5)),
        KeyChord(.pageUp), KeyChord("1", [.control, .option]),
        KeyChord(.down, [.option, .command]),
        KeyChord(.space), KeyChord(.delete, .command),
    ]
    #expect(
        chords.map(\.stored) == [
            "cmd+shift+k", "cmd++", "f5", "pageup", "ctrl+opt+1", "opt+cmd+down", "space",
            "cmd+delete",
        ])
    for chord in chords { #expect(KeyChord(stored: chord.stored) == chord) }
}

@Test func onlyTheStoredSpellingReadsBack() {
    for text in [
        "shift+cmd+k", "cmd+K", "Cmd+k", "f36", "cmd+", "cmd+ ", "", "cmd+shift", "meta+k",
    ] {
        #expect(KeyChord(stored: text) == nil, "\(text)")
    }
    #expect(KeyChord(stored: "+") == KeyChord("+"))
}

@Test func symbolsFollowTheMenuOrder() {
    #expect(KeyChord("k", [.command, .shift, .control, .option]).symbols == "⌃⌥⇧⌘K")
    #expect(KeyChord(.left, .command).symbols == "⌘←")
}

@Test func onlyModifiedChordsAndFunctionKeysBecomeKeyEquivalents() {
    #expect(KeyChord("k", .command).canBeKeyEquivalent)
    #expect(KeyChord(.function(1)).canBeKeyEquivalent)
    #expect(!KeyChord(.space).canBeKeyEquivalent)
    #expect(!KeyChord(.down, .shift).canBeKeyEquivalent)
    #expect(!KeyChord("a").canBeKeyEquivalent)
}

@Test func eventsGiveTheirChords() {
    let up = String(Character(Unicode.Scalar(UInt32(NSUpArrowFunctionKey))!))
    #expect(
        KeyChord.candidates(typed: up, unshifted: nil, flags: [.option, .numericPad, .function])
            == [KeyChord(.up, .option)])
    #expect(
        KeyChord.candidates(typed: "K", unshifted: nil, flags: [.shift, .command]) == [
            KeyChord("k", [.command, .shift])
        ])
    #expect(KeyChord.candidates(typed: " ", unshifted: nil, flags: []) == [KeyChord(.space)])
    #expect(
        KeyChord.candidates(typed: "\u{19}", unshifted: nil, flags: .shift) == [
            KeyChord(.tab, .shift)
        ])
    // ⇧⌘. on a US keyboard types ">", whose key is the period key.
    #expect(
        KeyChord.candidates(typed: ">", unshifted: ".", flags: [.shift, .command]) == [
            KeyChord(">", [.command, .shift]), KeyChord(".", [.command, .shift]),
        ])
}

@Test func keyEquivalentsUseAppKitsCharacters() {
    #expect(KeyChord(.delete, .command).keyEquivalent == "\u{8}")
    #expect(KeyChord("k", [.command, .shift]).keyEquivalent == "k")
    #expect(KeyChord("k", [.command, .shift]).keyEquivalentModifierMask == [.command, .shift])
}
