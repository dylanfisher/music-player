import Foundation
import HALOutput
import Log
import Playback
import Settings
import UPnPOutput

private let logger = moduleLogger()

/// What playback fell back to System Default from (ADR 0211).
enum OutputFallback {
    /// The device the config names, until the device output says it moved to System Default's
    /// device with this profile.
    case asked(DeviceProfile)
    /// The device the config names.
    case device
    /// The renderer the config names, which the engine goes back to when it answers again.
    case renderer(RendererOutput)

    var renderer: RendererOutput? {
        if case .renderer(let renderer) = self { renderer } else { nil }
    }
}

/// The device to fall back to once the output the config names went away, or nil to stay lost:
/// none when System Default is what went, or when it resolves to the device that went or can't
/// be read (ADR 0211). `lost` is the device output's device, which a renderer leaves idle.
func fallbackTarget(
    named: OutputChoice, lost: String?, systemDefault: () throws -> String
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

/// Falling back to System Default, paused, when the output the config names goes away, and
/// back when it returns. The config isn't written, so the choice survives (ADR 0211).
extension AppDelegate {
    /// Moves playback to System Default after a loss, unless it already fell back.
    func fallBack() {
        guard outputFallback == nil, let settings, let output, let engine,
            let uid = fallbackTarget(
                named: currentOutput, lost: outputUID,
                systemDefault: { try HALDeviceProvider.resolve(nil, snapshots: deviceSnapshots) })
        else { return }
        let target = profileState[\.deviceProfiles].profile(
            for: uid, config: outputConfig(settings), switched: true, typeHogs: typeHogs(uid))
        let choice: DeviceChoice
        do {
            try save(target)
            choice = try deviceChoice(target)
        } catch {
            return fail("Couldn't fall back to System Default", error)
        }
        guard let renderer = rendererOutput else {
            logger.notice("the output device went away; falling back to System Default, \(uid)")
            outputFallback = .asked(target)
            return output.fallBack(to: choice)
        }
        logger.notice("\(renderer.renderer.name) went away; falling back to System Default, \(uid)")
        // The engine played on the renderer, so the device output has nothing loaded.
        if uid != outputUID {
            output.use(choice)
            setInUse(target)
        }
        outputFallback = .renderer(renderer)
        rendererOutput = nil
        signalPath?.show(devicePath)
        receiverFollowsOutput()
        outputsChanged()
        Task { await engine.fallBack(to: output) }
    }

    /// The device output moved to System Default's device, so the volume is that device's.
    func fellBack() {
        guard case .asked(let target) = outputFallback else { return }
        outputFallback = .device
        setInUse(target)
        outputsChanged()
    }

    /// A device came back before the device output fell back from it, which then drops the
    /// fallback. Or the engine went back to the renderer it fell back from, so the device output
    /// goes back to the device the config names.
    func fallbackReturned() {
        if case .asked = outputFallback { outputFallback = nil }
        guard let renderer = outputFallback?.renderer, let engine else { return }
        Task {
            // A return of System Default's own device leaves the fallback as it is.
            guard await !engine.isFallenBack, outputFallback?.renderer === renderer else { return }
            outputFallback = nil
            rendererOutput = renderer
            receiverFollowsOutput()
            outputUID = nil
            outputSettingsChanged(switched: true)
            outputsChanged()
        }
    }

    /// Ends a fallback for a change of output setting, and returns whether there was one.
    func endFallback() -> Bool {
        guard let fallback = outputFallback else { return false }
        outputFallback = nil
        if let renderer = fallback.renderer { rendererOutput = renderer }
        // So the switch that follows isn't skipped as one to the device in use.
        outputUID = nil
        return true
    }
}
