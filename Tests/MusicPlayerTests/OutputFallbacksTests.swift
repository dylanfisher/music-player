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
    let (ended, renderer, fromDevice) = fallbacks.outputChanged(byApp: false)
    #expect(ended && renderer == nil)
    // The device output moves to the pick itself, so the engine is told the loss is over.
    #expect(fromDevice)
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
    let fromRendererEnding = fromRenderer.outputChanged(byApp: false)
    #expect(fromRendererEnding.renderer === denon)
    #expect(!fromRendererEnding.fromDevice)
    // Still asked, playback is lost on the device the config names, which the device output
    // reports a return from when it moves to the pick.
    var asked = OutputFallbacks<Renderer>()
    _ = asked.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "Speakers" },
        profile: { profile($0) })
    #expect(!asked.outputChanged(byApp: false).fromDevice)
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

@Test func aQuitClosesTheRendererFallenBackFrom() {
    let denon = Renderer()
    var fallbacks = OutputFallbacks<Renderer>()
    #expect(fallbacks.renderersToClose(denon).map(ObjectIdentifier.init) == [.init(denon)])
    _ = fallbacks.lost(
        named: .renderer(udn: "uuid:denon"), inUse: "DAC", renderer: denon,
        systemDefault: { "Speakers" }, profile: { profile($0) })
    // The app no longer holds it as the one playing.
    #expect(fallbacks.renderersToClose(nil).map(ObjectIdentifier.init) == [.init(denon)])
}

@Test func aNewLossAfterTheDeviceOutputDroppedTheFallbackFallsBack() {
    var fallbacks = OutputFallbacks<Renderer>()
    // Asked, and dropped by the device output: System Default's device had gone too.
    _ = fallbacks.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "Speakers" },
        profile: { profile($0) })
    // Play on the lost DAC loses it again, with another device now the default.
    let plan = fallbacks.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "Headphones" },
        profile: { profile($0) })
    #expect(plan?.profile == profile("Headphones"))
    let moved = fallbacks.fellBack()
    #expect(moved == profile("Headphones"))
    // And one with nothing to fall back to leaves no fallback asked.
    var stuck = OutputFallbacks<Renderer>()
    _ = stuck.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "Speakers" },
        profile: { profile($0) })
    let none = stuck.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "DAC" },
        profile: { profile($0) })
    #expect(none == nil && stuck.phase == nil)
}

@Test func aRenderersFallbackTheEngineDidntMakeHandsTheRendererBack() {
    let denon = Renderer()
    let named = OutputChoice.renderer(udn: "uuid:denon")
    var fallbacks = OutputFallbacks<Renderer>()
    _ = fallbacks.lost(
        named: named, inUse: "DAC", renderer: denon, systemDefault: { "Speakers" },
        profile: { profile($0) })
    let ended = fallbacks.abandon(ifRenderer: denon)
    #expect(ended)
    #expect(fallbacks.inUse(named: named) == named)
    #expect(fallbacks.renderersToClose(denon).count == 1)
}

@Test func aStaleRendererAbandonLeavesANewerFallback() {
    let denon = Renderer()
    let sonos = Renderer()
    var fallbacks = OutputFallbacks<Renderer>()
    _ = fallbacks.lost(
        named: .renderer(udn: "uuid:denon"), inUse: "DAC", renderer: denon,
        systemDefault: { "Speakers" }, profile: { profile($0) })
    // The user picks the Sonos, which goes too, before the engine's answer for the Denon.
    _ = fallbacks.outputChanged(byApp: false)
    _ = fallbacks.lost(
        named: .renderer(udn: "uuid:sonos"), inUse: "DAC", renderer: sonos,
        systemDefault: { "Speakers" }, profile: { profile($0) })
    let stale = fallbacks.abandon(ifRenderer: denon)
    #expect(!stale)
    #expect(fallbacks.renderer === sonos)
}

@Test func pickingTheChosenOutputDuringAFallbackEndsIt() {
    var fallbacks = OutputFallbacks<Renderer>()
    // Lost, not yet moved: the pick is the one in use, and changes nothing.
    _ = fallbacks.lost(
        named: dac, inUse: "DAC", renderer: nil, systemDefault: { "Speakers" },
        profile: { profile($0) })
    #expect(!fallbacks.pickEnds(dac, named: dac))
    _ = fallbacks.fellBack()
    #expect(fallbacks.pickEnds(dac, named: dac))
    // Any other pick changes a setting, which ends it as a change does.
    #expect(!fallbacks.pickEnds(.systemDefault, named: dac))
    #expect(!fallbacks.pickEnds(.device(uid: "Speakers"), named: dac))
}

@Test func aRendererPickedAgainStaysLostUntilItReturns() {
    let denon = Renderer()
    let named = OutputChoice.renderer(udn: "uuid:denon")
    var fallbacks = OutputFallbacks<Renderer>()
    _ = fallbacks.lost(
        named: named, inUse: "DAC", renderer: denon, systemDefault: { "Speakers" },
        profile: { profile($0) })
    _ = fallbacks.outputChanged(byApp: false)
    fallbacks.pickedAgain(denon)
    // The engine's move back reports it lost, which doesn't fall back again.
    let again = fallbacks.lost(
        named: named, inUse: "DAC", renderer: denon, systemDefault: { "Speakers" },
        profile: { profile($0) })
    #expect(again == nil)
    #expect(fallbacks.inUse(named: named) == named)
    // Once it has returned, a loss falls back as before.
    _ = fallbacks.deviceReturned()
    let later = fallbacks.lost(
        named: named, inUse: "DAC", renderer: denon, systemDefault: { "Speakers" },
        profile: { profile($0) })
    #expect(later?.leavesRenderer == true)
}

@Test func aRendererTakingOverEndsTheFallback() {
    let denon = Renderer()
    let named = OutputChoice.renderer(udn: "uuid:denon")
    // The DAC went while the search for the Denon ran, and playback fell back.
    var fallbacks = fellBackFromTheDAC()
    let leftBehind = fallbacks.rendererTookOver()
    #expect(leftBehind == nil)
    #expect(!fallbacks.hasMoved)
    #expect(fallbacks.inUse(named: named) == named)
    // So the Denon's own loss falls back.
    let plan = fallbacks.lost(
        named: named, inUse: "Speakers", renderer: denon, systemDefault: { "Speakers" },
        profile: { profile($0) })
    #expect(plan?.leavesRenderer == true)
    // A renderer's fallback hands back the renderer it left, for the app to close.
    let handedBack = fallbacks.rendererTookOver()
    #expect(handedBack === denon)
}
