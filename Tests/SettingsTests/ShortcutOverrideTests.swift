import KeyChord
import Testing

@testable import Settings

@Test func aPositionReadsAndWritesItsSlot() {
    var override = ShortcutOverride()
    #expect(override.isEmpty)
    override[.alternate] = .chord(KeyChord("j", .command))
    #expect(override.alternate == .chord(KeyChord("j", .command)))
    #expect(override[.primary] == nil)
    #expect(!override.isEmpty)
    override[.primary] = .removed
    #expect(override.primary == .removed)
    override[.alternate] = nil
    override[.primary] = nil
    #expect(override == ShortcutOverride())
}
