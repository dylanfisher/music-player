import Testing

@testable import MusicPlayer
@testable import Settings

private struct NoDefault: Error {}

/// Stands in for the renderer output a fallback leaves.
private final class Renderer {}

private func profile(_ uid: String, hogMode: Bool = false) -> DeviceProfile {
    DeviceProfile(uid: uid, hogMode: hogMode, digitalVolume: true, volumeDecibels: -6, formats: nil)
}

private let dac = OutputChoice.device(uid: "DAC")

/// The DAC the config names lost, and playback fallen back to the speakers.
private func fellBackFromTheDAC() -> OutputFallbacks<Renderer> {
    var fallbacks = OutputFallbacks<Renderer>()
    _ = fallbacks.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "Speakers" },
        profile: { profile($0) })
    _ = fallbacks.fellBack()
    return fallbacks
}

@Test func aChosenDeviceThatWentFallsBackToSystemDefaultOnceTheOutputSaysSo() {
    var fallbacks = OutputFallbacks<Renderer>()
    let plan = fallbacks.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "Speakers" },
        profile: { profile($0) })
    #expect(plan == .init(profile: profile("Speakers"), device: .fallBack, leavesRenderer: false))
    // Lost on the DAC until the device output has moved.
    #expect(fallbacks.inUse(named: dac) == dac)
    let moved = fallbacks.fellBack()
    #expect(moved == profile("Speakers"))
    #expect(fallbacks.inUse(named: dac) == .systemDefault)
    let again = fallbacks.fellBack()
    #expect(again == nil)
}

@Test func aSecondLossDuringAFallbackStaysLost() {
    var fallbacks = fellBackFromTheDAC()
    let plan = fallbacks.lost(
        named: dac, inUse: "Speakers", renderer: nil, systemDefault: { "Other" },
        profile: { profile($0) })
    #expect(plan == nil)
    #expect(fallbacks.inUse(named: dac) == .systemDefault)
}

@Test func systemDefaultItselfLostStaysLost() {
    for (named, systemDefault) in [
        (OutputChoice.systemDefault, { "Speakers" }),
        // macOS hasn't moved its default off the device that went, or there's none at all.
        (dac, { "DAC" }), (dac, { throw NoDefault() }),
    ] as [(OutputChoice, () throws -> String)] {
        var fallbacks = OutputFallbacks<Renderer>()
        let plan = fallbacks.lost(
            named: named, inUse: "DAC", renderer: nil, systemDefault: systemDefault,
            profile: { profile($0) })
        #expect(plan == nil)
        #expect(!fallbacks.hasMoved)
    }
}

@Test func aDeviceBackBeforeTheOutputMovedEndsTheFallback() {
    var fallbacks = OutputFallbacks<Renderer>()
    _ = fallbacks.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "Speakers" },
        profile: { profile($0) })
    let renderer = fallbacks.deviceReturned()
    #expect(renderer == nil)
    #expect(fallbacks.phase == nil)
    let moved = fallbacks.fellBack()
    #expect(moved == nil)
}

@Test func aRendererThatWentFallsBackAndTheEnginesReturnEndsIt() {
    let denon = Renderer()
    let named = OutputChoice.renderer(udn: "uuid:denon")
    var fallbacks = OutputFallbacks<Renderer>()
    let plan = fallbacks.lost(
        named: named, inUse: "DAC", renderer: denon, systemDefault: { "Speakers" },
        profile: { profile($0) })
    #expect(plan == .init(profile: profile("Speakers"), device: .use, leavesRenderer: true))
    #expect(fallbacks.renderer === denon)
    #expect(fallbacks.inUse(named: named) == .systemDefault)
    // A return the device output reported doesn't end it, nor does one while the engine is
    // still on the device output.
    fallbacks.deviceOutputReturned()
    let reported = fallbacks.deviceReturned()
    #expect(reported === denon)
    let stillFallenBack = fallbacks.rendererReturned(denon, isFallenBack: true)
    let another = fallbacks.rendererReturned(Renderer(), isFallenBack: false)
    #expect(!stillFallenBack && !another)
    let back = fallbacks.rendererReturned(denon, isFallenBack: false)
    #expect(back)
    #expect(fallbacks.inUse(named: named) == named)
}

@Test func aRendererThatWentWithTheDeviceOutputOnSystemDefaultLeavesItThere() {
    var fallbacks = OutputFallbacks<Renderer>()
    let plan = fallbacks.lost(
        named: .renderer(udn: "uuid:denon"), inUse: "Speakers", renderer: Renderer(),
        systemDefault: { "Speakers" }, profile: { profile($0) })
    #expect(plan?.device == .stay)
}

@Test func theUsersPickEndsTheFallback() {
    var fallbacks = fellBackFromTheDAC()
    let (ended, renderer) = fallbacks.outputChanged(byApp: false)
    #expect(ended && renderer == nil)
    #expect(fallbacks.inUse(named: .systemDefault) == .systemDefault)
    #expect(fallbacks.inUse(named: dac) == dac)
    let again = fallbacks.outputChanged(byApp: false)
    #expect(!again.ended)
    // A renderer's ending hands the renderer back to the app.
    let denon = Renderer()
    var fromRenderer = OutputFallbacks<Renderer>()
    _ = fromRenderer.lost(
        named: .renderer(udn: "uuid:denon"), inUse: "DAC", renderer: denon,
        systemDefault: { "Speakers" }, profile: { profile($0) })
    let handedBack = fromRenderer.outputChanged(byApp: false).renderer
    #expect(handedBack === denon)
}

@Test func aHogModeEditDuringAFallbackIsTheChosenDevicesAndMovesNothing() {
    let fallbacks = fellBackFromTheDAC()
    // The config shows the DAC's settings, so turning hog mode on there saves the DAC's
    // profile; the output stays on the speakers, and nothing writes the config.
    #expect(fallbacks.savesOnly(profile("DAC", hogMode: true), switched: false, inUse: "Speakers"))
    // A change of device, or an edit on the device in use, applies as usual.
    #expect(!fallbacks.savesOnly(profile("Speakers"), switched: true, inUse: "Speakers"))
    #expect(!fallbacks.savesOnly(profile("Speakers"), switched: false, inUse: "Speakers"))
    #expect(!OutputFallbacks<Renderer>().savesOnly(profile("DAC"), switched: false, inUse: "X"))
}

@Test func theDeviceOutputsReturnEndsADevicesFallback() {
    var fallbacks = fellBackFromTheDAC()
    fallbacks.deviceOutputReturned()
    #expect(!fallbacks.hasMoved)
    #expect(fallbacks.inUse(named: dac) == dac)
}

@Test func theAppsOwnWriteOfTheOutputLeavesTheFallback() {
    let denon = Renderer()
    let named = OutputChoice.renderer(udn: "uuid:denon")
    var fallbacks = OutputFallbacks<Renderer>()
    _ = fallbacks.lost(
        named: named, inUse: "DAC", renderer: denon, systemDefault: { "Speakers" },
        profile: { profile($0) })
    // As when the device output returns to a device on its own and the config is made to
    // show it.
    let shown = fallbacks.outputChanged(byApp: true)
    #expect(!shown.ended && shown.renderer == nil)
    #expect(fallbacks.renderer === denon)
    #expect(fallbacks.inUse(named: named) == .systemDefault)
}

@Test func duringAFallbackTheHogModeShownAndFixedIsTheDeviceInUsesOrNone() {
    let fallbacks = fellBackFromTheDAC()
    // The config shows the DAC's hog mode; the speakers play with their own.
    #expect(fallbacks.hogModeShown(config: true, inUse: false) == false)
    #expect(!fallbacks.takesHogModeFix)
    let none = OutputFallbacks<Renderer>()
    #expect(none.hogModeShown(config: true, inUse: false) == true)
    #expect(none.takesHogModeFix)
}
