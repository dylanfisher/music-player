import Testing

@testable import MusicPlayer
@testable import Settings

private struct NoDefault: Error {}

@Test func aChosenDeviceThatWentFallsBackToSystemDefault() {
    #expect(
        fallbackTarget(named: .device(uid: "DAC"), lost: "DAC", systemDefault: { "Speakers" })
            == "Speakers")
}

@Test func aChosenRendererThatWentFallsBackToSystemDefault() {
    // The device output is idle on System Default's device already, or on another.
    #expect(
        fallbackTarget(
            named: .renderer(udn: "uuid:denon"), lost: "Speakers", systemDefault: { "Speakers" })
            == "Speakers")
}

@Test func systemDefaultItselfLostStaysLost() {
    #expect(
        fallbackTarget(named: .systemDefault, lost: "Speakers", systemDefault: { "Speakers" })
            == nil)
    // macOS hasn't moved its default off the device that went, or there's none at all.
    let dac = OutputChoice.device(uid: "DAC")
    #expect(fallbackTarget(named: dac, lost: "DAC", systemDefault: { "DAC" }) == nil)
    #expect(fallbackTarget(named: dac, lost: "DAC", systemDefault: { throw NoDefault() }) == nil)
}
