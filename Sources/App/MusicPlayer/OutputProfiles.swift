import Foundation
import HALOutput
import Log
import Playback
import Settings

private let logger = moduleLogger()

/// Each output device's profile, and the config's output settings showing the device in use
/// (ADR 0037).
extension AppDelegate {
    /// Moves the output to the device and settings the config names now, mid-track if one is
    /// playing. `switched` says whether the config's device changed (ADR 0037).
    func outputSettingsChanged(switched: Bool) {
        guard let settings, let output, !showingInUse else { return }
        do {
            let profile = try outputProfile(settings, switched: switched)
            // While System Default plays in its place, the config shows the chosen device's
            // settings, so an edit is that device's (ADR 0211).
            if outputFallback != nil, !switched, profile.uid != outputUID {
                return try save(profile)
            }
            if let inUse = inUseProfile, inUse.uid == profile.uid, inUse.hogMode == profile.hogMode,
                inUse.digitalVolume == profile.digitalVolume
            {
                return
            }
            try save(profile)
            output.use(try deviceChoice(profile))
            showInUse(profile, settings)
        } catch {
            fail("Couldn't switch the output device", error)
        }
    }

    /// The output went back on its own to a device that came back.
    func outputReturned(to uid: String) {
        guard let settings, let state else { return }
        // It was in use before, so it has a profile, and its kind isn't read.
        let profile = state[\.deviceProfiles].profile(
            for: uid, config: outputConfig(settings), switched: true, typeHogs: nil)
        do {
            try save(profile)
        } catch {
            logger.error("couldn't save \(uid)'s profile: \(error)")
        }
        // A device fallen back from is back; a renderer's fallback ends when the engine says.
        if outputFallback?.renderer == nil { outputFallback = nil }
        showInUse(profile, settings)
        outputsChanged()
    }

    var inUseProfile: DeviceProfile? {
        state?[\.deviceProfiles].profiles.first { $0.uid == outputUID }
    }

    func outputConfig(_ settings: ConfigStore<AppSettings>) -> OutputConfig {
        OutputConfig(hogMode: settings[\.hogMode], digitalVolume: settings[\.digitalVolume])
    }

    func outputProfile(_ settings: ConfigStore<AppSettings>, switched: Bool) throws
        -> DeviceProfile
    {
        let uid = try HALDeviceProvider.resolve(
            settings[\.outputDeviceUID], snapshots: deviceSnapshots)
        return profileState[\.deviceProfiles].profile(
            for: uid, config: outputConfig(settings), switched: switched, typeHogs: typeHogs(uid))
    }

    /// Whether a device seen for the first time hogs, from its transport type. A device whose
    /// type can't be read starts from `output.hogMode`, as one not connected does.
    func typeHogs(_ uid: String) -> Bool? {
        do {
            return try HALDeviceProvider.hogsByDefault(uid)
        } catch {
            logger.error(
                "can't read \(uid)'s transport type; it starts from output.hogMode: \(error)")
            return nil
        }
    }

    /// Written before the output uses it, so a crash never leaves the device with settings its
    /// profile doesn't hold.
    func save(_ profile: DeviceProfile) throws {
        try profileState.set(\.deviceProfiles, to: profileState[\.deviceProfiles].using(profile))
    }

    var profileState: StateStore<AppState> {
        guard let state else { preconditionFailure("the state file opens before playback starts") }
        return state
    }

    func deviceChoice(_ profile: DeviceProfile) throws -> DeviceChoice {
        DeviceChoice(
            provider: try HALDeviceProvider(
                deviceUID: profile.uid, hogMode: profile.hogMode,
                restoreRecordURL: restoreRecordURL(in: paths.dataDirectory),
                snapshots: deviceSnapshots),
            digitalVolume: profile.digitalVolume, gain: pow(10, profile.volumeDecibels / 20),
            formats: profile.formats)
    }

    /// Makes `profile` the one in use, and the config's output settings show it, so the menus
    /// and the settings window read what the device plays with.
    func showInUse(_ profile: DeviceProfile, _ settings: ConfigStore<AppSettings>) {
        setInUse(profile)
        showingInUse = true
        defer { showingInUse = false }
        do {
            // Null, the system default, is left alone while it still names this device.
            let named = settings[\.outputDeviceUID]
            if named != profile.uid,
                try named != nil
                    || HALDeviceProvider.resolve(nil, snapshots: deviceSnapshots) != profile.uid
            {
                try settings.set(\.outputDeviceUID, to: profile.uid)
            }
            if settings[\.hogMode] != profile.hogMode {
                try settings.set(\.hogMode, to: profile.hogMode)
            }
            if settings[\.digitalVolume] != profile.digitalVolume {
                try settings.set(\.digitalVolume, to: profile.digitalVolume)
            }
        } catch {
            logger.error("couldn't show \(profile.uid)'s settings in the config: \(error)")
        }
    }

    /// Makes `profile` the one the volume changes, without writing the config.
    func setInUse(_ profile: DeviceProfile) {
        outputUID = profile.uid
        digitalVolume = profile.digitalVolume
        volumeDecibels = profile.volumeDecibels
    }

    /// Records the rates and formats the device in the path reported, when they changed.
    func recordFormats(_ path: SignalPath) {
        guard case .device(let sink) = path.sink, case .connected(let signal) = sink.state,
            let state,
            let next = state[\.deviceProfiles].reporting(signal.formats, for: sink.uid)
        else { return }
        do {
            try state.set(\.deviceProfiles, to: next)
        } catch {
            logger.error("couldn't record \(sink.uid)'s formats: \(error)")
        }
    }

    /// Saves the digital volume in the profile of the device in use, before it's applied.
    func saveVolume(_ decibels: Double) {
        guard var profile = inUseProfile else { return }
        profile.volumeDecibels = decibels
        do {
            try save(profile)
        } catch {
            logger.error("couldn't save the volume in \(profile.uid)'s profile: \(error)")
        }
    }
}
