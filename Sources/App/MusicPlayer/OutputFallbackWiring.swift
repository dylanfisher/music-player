import Foundation
import HALOutput
import Log
import Playback
import Settings
import UPnPOutput

private let logger = moduleLogger()

/// Falling back to System Default, paused, when the output the config names goes away, and
/// back when it returns, as `OutputFallbacks` decides. The config isn't written, so the choice
/// survives (ADR 0211).
extension AppDelegate {
    /// Moves playback to System Default after a loss, unless it already fell back.
    func fallBack() {
        guard let settings, let output, let engine,
            let plan = outputFallback.lost(
                named: currentOutput, inUse: outputUID, renderer: rendererOutput,
                systemDefault: { try HALDeviceProvider.resolve(nil, snapshots: deviceSnapshots) },
                profile: { uid in
                    profileState[\.deviceProfiles].profile(
                        for: uid, config: outputConfig(settings), switched: true,
                        typeHogs: typeHogs(uid))
                })
        else { return }
        let choice: DeviceChoice
        do {
            try save(plan.profile)
            choice = try deviceChoice(plan.profile)
        } catch {
            outputFallback.abandon()
            return fail("Couldn't fall back to System Default", error)
        }
        let uid = plan.profile.uid
        switch plan.device {
        case .fallBack:
            logger.notice("the output device went away; falling back to System Default, \(uid)")
            output.fallBack(to: choice)
        case .use:
            output.use(choice)
            setInUse(plan.profile)
        case .stay: break
        }
        guard plan.leavesRenderer, let renderer = rendererOutput else { return }
        logger.notice("\(renderer.renderer.name) went away; falling back to System Default, \(uid)")
        rendererOutput = nil
        signalPath?.show(devicePath)
        receiverFollowsOutput()
        outputsChanged()
        Task { await engine.fallBack(to: output) }
    }

    /// The device output moved to System Default's device, so the volume is that device's.
    func fellBack() {
        guard let target = outputFallback.fellBack() else { return }
        setInUse(target)
        outputsChanged()
    }

    /// The engine reported an output's return: maybe the renderer fallen back from, so the
    /// device output goes back to the device the config names.
    func fallbackReturned() {
        guard let renderer = outputFallback.deviceReturned(), let engine else { return }
        Task {
            let fallenBack = await engine.isFallenBack
            guard outputFallback.rendererReturned(renderer, isFallenBack: fallenBack) else {
                return
            }
            rendererOutput = renderer
            receiverFollowsOutput()
            outputUID = nil
            outputSettingsChanged(switched: true)
            outputsChanged()
        }
    }

    /// Ends a fallback for a change of output setting, and returns whether there was one.
    func endFallback() -> Bool {
        let (ended, renderer) = outputFallback.end()
        guard ended else { return false }
        if let renderer { rendererOutput = renderer }
        // So the switch that follows isn't skipped as one to the device in use.
        outputUID = nil
        return true
    }
}
