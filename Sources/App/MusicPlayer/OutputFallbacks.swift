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

    /// Decides the fallback after the output in use went away, or nil to stay lost: during a
    /// fallback, when the config names System Default, when System Default resolves to the
    /// device that went (`inUse`, the device output's), or when it can't be resolved.
    /// `renderer` is the one playing, when one is.
    mutating func lost(
        named: OutputChoice, inUse: String?, renderer: Renderer?,
        systemDefault: () throws -> String, profile: (String) -> DeviceProfile
    ) -> Plan? {
        guard phase == nil, let uid = Self.target(named, lost: inUse, systemDefault)
        else { return nil }
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

    /// Ends the fallback for a change of output. Returns whether there was one, and the
    /// renderer fallen back from, which is the app's again to close or keep.
    mutating func end() -> (ended: Bool, renderer: Renderer?) {
        guard phase != nil else { return (false, nil) }
        defer { phase = nil }
        return (true, renderer)
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
