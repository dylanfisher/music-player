import Testing

@testable import MusicPlayer

private func keys(_ bytes: [UInt8]) -> [Key] {
    var parser = KeyParser()
    return bytes.compactMap { parser.key(after: $0) }
}

private let escape: UInt8 = 0x1B

@Test func arrowsInBothModesBecomeSeeks() {
    #expect(keys([escape, UInt8(ascii: "["), UInt8(ascii: "C")]) == [.forward])
    #expect(keys([escape, UInt8(ascii: "O"), UInt8(ascii: "D")]) == [.back])
}

@Test func aByteAfterALoneEscapeIsReadAsItsOwnKey() {
    #expect(keys([escape, UInt8(ascii: "q")]) == [.quit])
    #expect(keys([escape, UInt8(ascii: " "), UInt8(ascii: "n")]) == [.space, .next])
}

@Test func otherSequencesAreIgnored() {
    #expect(keys([escape, UInt8(ascii: "["), UInt8(ascii: "A"), UInt8(ascii: "p")]) == [.previous])
}
