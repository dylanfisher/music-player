import Testing

@testable import KeyChord

/// `data1` as the system packs it: the key in the high 16 bits, the state in bits 8 to 15,
/// and the repeat flag in bit 0.
private func data1(key: Int, down: Bool, repeating: Bool = false) -> Int {
    key << 16 | (down ? 0xA : 0xB) << 8 | (repeating ? 1 : 0)
}

@Test func soundKeyPressesAndRepeatsAreReadAndReleasesHeld() {
    #expect(MediaKey(subtype: 8, data1: data1(key: 0, down: true)) == .volumeUp)
    #expect(MediaKey(subtype: 8, data1: data1(key: 1, down: true, repeating: true)) == .volumeDown)
    #expect(MediaKey(subtype: 8, data1: data1(key: 7, down: true)) == .mute)
    // A release is a sound key, swallowed with its press, but no press of its own.
    #expect(MediaKey(subtype: 8, data1: data1(key: 0, down: false)) == nil)
    #expect(MediaKey.isSoundKey(subtype: 8, data1: data1(key: 0, down: false)))
}

@Test func otherKeysAndSubtypesAreLeftToTheSystem() {
    // Play (16), next (17), brightness up (2), and a sound key under another subtype.
    for key in [16, 17, 2] {
        #expect(MediaKey(subtype: 8, data1: data1(key: key, down: true)) == nil)
        #expect(!MediaKey.isSoundKey(subtype: 8, data1: data1(key: key, down: true)))
    }
    #expect(!MediaKey.isSoundKey(subtype: 7, data1: data1(key: 0, down: true)))
}
