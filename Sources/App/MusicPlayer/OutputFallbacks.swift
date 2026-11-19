import Log
import Settings

private let logger = moduleLogger()

/// Where playback stands in a fallback to System Default, and what each step of one decides,
/// with no AppKit, device or network in it, so tests drive it with stand-ins (ADR 0211). The
/// app makes the moves it decides on. `Renderer` is the renderer output a fallback leaves.
struct OutputFallbacks<Renderer: AnyObject> {
    enum Phase {
        /// The device output was asked to move to this profile's device and hasn't said it did.
        /// Until it does, playback is lost on the device the config names.
        case asked(DeviceProfile)
        /// Playback is on System Default in place of the device the config names.
        case device
        /// Playback is on the device output in place of this renderer, which the engine goes
        /// back to when it answers again.
        case renderer(Renderer)
    }

    /// What a loss moves, with System Default's profile, which is saved before an output uses
    /// it.
    struct Plan: Equatable {
        enum Device: Equatable {
            /// `DeviceOutput.fallBack(to:)`, from the device that went.
            case fallBack
            /// `DeviceOutput.use(_:)`, which a renderer left idle on another device, and the
            /// volume becomes the profile's, without writing the config.
            case use
            /// The device output is on System Default's device already.
            case stay
        }

        var profile: DeviceProfile
        var device: Device
        /// The engine falls back from the renderer to the device output.
        var leavesRenderer: Bool
    }

    private(set) var phase: Phase?
    /// The renderer the user picked again during its fallback, lost still: its loss stays one,
    /// with no fallback, until it returns or another output is picked.
    private var repicked: Renderer?

    /// The renderer fallen back from, while playback is on the device output in its place.
    var renderer: Renderer? {
        if case .renderer(let renderer) = phase { renderer } else { nil }
    }

    /// Whether playback is on System Default in place of the output the config names.
    var hasMoved: Bool {
        switch phase {
        case .device, .renderer: true
        case .asked, nil: false
        }
    }

    /// The output the pickers check: System Default once playback is on it, otherwise the one
    /// the config names, `named`.
    func inUse(named: OutputChoice) -> OutputChoice { hasMoved ? .systemDefault : named }

    /// Decides the fallback after the output in use went away, or nil to stay lost: once
    /// playback has moved, when the config names System Default, when System Default resolves
    /// to the device that went (`inUse`, the device output's), or when it can't be resolved.
    /// `renderer` is the one playing, when one is. A fallback still asked was dropped by the
    /// device output, as when System Default's device went too, so a new loss decides afresh.
    mutating func lost(
        named: OutputChoice, inUse: String?, renderer: Renderer?,
        systemDefault: () throws -> String, profile: (String) -> DeviceProfile
    ) -> Plan? {
        guard !hasMoved, renderer == nil || renderer !== repicked else { return nil }
        phase = nil
        guard let uid = Self.target(named, lost: inUse, systemDefault) else { return nil }
        let target = profile(uid)
        guard let renderer else {
            phase = .asked(target)
            return Plan(profile: target, device: .fallBack, leavesRenderer: false)
        }
        phase = .renderer(renderer)
        return Plan(profile: target, device: uid == inUse ? .stay : .use, leavesRenderer: true)
    }

    /// A plan that couldn't be made, as when its profile wasn't saved: playback stays lost.
    mutating func abandon() { phase = nil }

    /// A renderer's fallback the engine didn't make, as when Play reached the renderer first:
    /// it ends, and the renderer plays still, if the fallback is still `renderer`'s. A pick
    /// and another loss since may have started another fallback, which it leaves. True when
    /// it ended one.
    mutating func abandon(ifRenderer renderer: Renderer) -> Bool {
        guard self.renderer === renderer else { return false }
        phase = nil
        return true
    }

    /// The device output moved to System Default's device. Returns its profile, which the
    /// volume becomes, without writing the config.
    mutating func fellBack() -> DeviceProfile? {
        guard case .asked(let target) = phase else { return nil }
        phase = .device
        return target
    }

    /// The engine said an output returned. A device that came back before the device output
    /// moved off it ends the fallback, which the output drops. Returns the renderer fallen back
    /// from, whose return the engine may be reporting.
    mutating func deviceReturned() -> Renderer? {
        if case .asked = phase { phase = nil }
        repicked = nil
        return renderer
    }

    /// The engine plays on `renderer` again, unless it `isFallenBack` still, as when System
    /// Default's own device returned. True when the fallback ended: the device output then
    /// goes back to the device the config names, and the config shows it.
    mutating func rendererReturned(_ renderer: Renderer, isFallenBack: Bool) -> Bool {
        guard !isFallenBack, self.renderer === renderer else { return false }
        phase = nil
        return true
    }

    /// The device output went back on its own to a device that returned (ADR 0037), which ends
    /// a device's fallback. A renderer's ends when the engine goes back to it.
    mutating func deviceOutputReturned() {
        if renderer == nil { phase = nil }
    }

    /// Whether an edit of the output settings only saves `profile`, the device's the config
    /// names: once playback is on System Default in its place, the config shows that device's
    /// settings, so an edit is that device's, and the output stays (ADR 0211). Not for a change
    /// of device (`switched`), or when the config's device is the one in use.
    func savesOnly(_ profile: DeviceProfile, switched: Bool, inUse: String?) -> Bool {
        hasMoved && !switched && profile.uid != inUse
    }

    /// The renderers to close at quit: `current`, the one playing, and the one fallen back
    /// from, whose server, probe and sleep assertion run until it's closed.
    func renderersToClose(_ current: Renderer?) -> [Renderer] {
        [current, renderer].compactMap { $0 }
    }

    /// The hog mode a problem's details show for the device in use: the config's, which
    /// mirrors that device's profile, `inUse`, except once playback is on System Default, when
    /// the config shows the chosen device's (ADR 0211).
    func hogModeShown(config: Bool, inUse: Bool?) -> Bool? { hasMoved ? inUse : config }

    /// Whether Turn On Hog Mode, which sets the config's hog mode, reaches the device in use.
    /// Not once playback is on System Default: it would turn it on for the chosen device. The
    /// user's pick of System Default ends the fallback, and the fix works then.
    var takesHogModeFix: Bool { !hasMoved }

    /// The user picked `renderer`, the one fallen back from, again: the engine goes back to it
    /// lost, and its losses fall back to nothing until it returns.
    mutating func pickedAgain(_ renderer: Renderer) { repicked = renderer }

    /// Whether a pick of `choice` ends the fallback, though it changes no setting: it's the
    /// output the config names, `named`, listed as not connected while System Default plays
    /// in its place, so picking it asks for that output again (ADR 0211).
    func pickEnds(_ choice: OutputChoice, named: OutputChoice) -> Bool {
        hasMoved && choice == named
    }

    /// Ends the fallback for a change of `output.deviceUID` or `output.renderer`, unless the
    /// app made it `byApp` to show the device in use: only the user's change ends one. Returns
    /// whether it ended; the renderer fallen back from, which is the app's again to close or
    /// keep; and whether it was a device's fallback the device output made, whose loss the
    /// engine wasn't told is over, since the device output moves to the pick itself.
    mutating func outputChanged(byApp: Bool) -> (
        ended: Bool, renderer: Renderer?, fromDevice: Bool
    ) {
        if !byApp { repicked = nil }
        guard phase != nil, !byApp else { return (false, nil, false) }
        defer { phase = nil }
        if case .device = phase { return (true, nil, true) }
        return (true, renderer, false)
    }

    private static func target(
        _ named: OutputChoice, lost: String?, _ systemDefault: () throws -> String
    ) -> String? {
        if case .systemDefault = named { return nil }
        let target: String
        do {
            target = try systemDefault()
        } catch {
            logger.error("there's no System Default to fall back to: \(error)")
            return nil
        }
        if case .device = named, target == lost { return nil }
        return target
    }
}
