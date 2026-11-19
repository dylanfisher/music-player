/// Why `DeviceOutput.fallBack(to:)` is dropped, for the log, or nil to fall back to `target`:
/// the device in use is back (`missing` false), as after a plug-in before the app asked, or
/// `target` went too, so output stays lost on the one in use (ADR 0211).
func whyNotFallBack(missing: Bool, to target: any PCMDeviceProvider) -> String? {
    if !missing { return "the device in use is back, so there's nothing to fall back from" }
    if !target.isConnected() { return "it isn't connected either, so playback stays lost" }
    return nil
}
