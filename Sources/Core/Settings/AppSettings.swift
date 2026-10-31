/// Every setting the app has.
public struct AppSettings: SettingsSchema {
    public init() {}

    public let outputDeviceUID = Setting<String?>(
        "output.deviceUID", default: nil,
        "The output device, by its Core Audio UID, so it survives a rename. Null means the system"
            + " default output.")
    public let hogMode = Setting(
        "output.hogMode", default: true,
        "Take exclusive access to the output device while playing, so no other app can play"
            + " through it or change its format.")
    public let digitalVolume = Setting(
        "output.digitalVolume", default: false,
        "Let the app turn the volume down itself. Output is no longer bit-perfect while the volume"
            + " is below full, because every sample is scaled. Off means the DAC or amplifier sets"
            + " the volume.")
    public let watchedFolders = Setting<[WatchedFolder]>(
        "library.watchedFolders", default: [], "Folders the library scans and watches for changes.")
    public let pausePollingDuringPlayback = Setting(
        "library.pausePollingDuringPlayback", default: false,
        "Don't rescan network folders while music is playing.")
    /// What `networkScanReaders` and `--scan --readers` accept; a scan starts that many threads.
    public static let networkScanReadersRange = 1...64
    public let networkScanReaders = Setting<Int?>(
        "library.networkScanReaders", default: nil, range: networkScanReadersRange,
        "Files a scan of a network folder reads at once. Null tunes the number to the network"
            + " and NAS while each scan runs.")
}
