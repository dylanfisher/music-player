/// Every setting the app has.
public struct AppSettings: SettingsSchema {
    public init() {}

    public let outputDeviceUID = Setting<String?>(
        "output.deviceUID", title: "Output Device", default: nil,
        "The output device, by its Core Audio UID, so it survives a rename. Null means the system"
            + " default output.")
    public let hogMode = Setting(
        "output.hogMode", title: "Hog Mode", default: true,
        "Take exclusive access to the output device while playing, so no other app can play"
            + " through it or change its format.")
    public let digitalVolume = Setting(
        "output.digitalVolume", title: "Digital Volume", default: false,
        "Let the app turn the volume down itself. Output is no longer bit-perfect while the volume"
            + " is below full, because every sample is scaled. Off means the DAC or amplifier sets"
            + " the volume.")
    public let watchedFolders = Setting<[WatchedFolder]>(
        "library.watchedFolders", title: "Watched Folders", default: [],
        "Folders the library scans and watches for changes.")
    public let pausePollingDuringPlayback = Setting(
        "library.pausePollingDuringPlayback", title: "Pause Network Rescans While Playing",
        default: false,
        "Don't rescan network folders while music is playing.")
    /// What `networkScanReaders` and `--scan --readers` accept; a scan starts that many threads.
    public static let networkScanReadersRange = 1...64
    public let networkScanReaders = Setting<Int?>(
        "library.networkScanReaders", title: "Network Scan Readers", default: nil,
        range: networkScanReadersRange,
        "Files a scan of a network folder reads at once. Null tunes the number to the network"
            + " and NAS while each scan runs.")
    public let syncFolder = Setting<SyncFolder?>(
        "sync.folder", title: "Sync Folder", default: nil,
        "A folder outside every watched folder through which the Macs that play this library"
            + " share plays, ratings, loved tracks, playlists and Date Added, each appending to a"
            + " log of its own: {\"share\": \"smb://nas/music\", \"path\": \"sync\"} on a share,"
            + " or {\"path\": \"/Users/me/Sync\"}. Only folders stored by share are shared, by"
            + " their path in the share, so Macs pointed at separate copies of the music share"
            + " nothing. Null shares nothing.")
    public let groupByAlbumArtist = Setting(
        "library.groupByAlbumArtist", title: "Group by Album Artist", default: true,
        "List album artists in the Artist pane, with the track artist where a track has none and"
            + " compilations without one under Various Artists, and sort by Artist or Album with"
            + " each album's tracks together. Off lists every track artist.")
    public let receiverEnabled = Setting(
        "receiver.enabled", title: "Receiver Control", default: false,
        "Find a Denon receiver on the local network and control its volume, mute, sound mode,"
            + " input and power. The receiver's IP Control setting must be Always On to reach it"
            + " in standby. Off, the app sends nothing onto the network.")
    public let receiverAddress = Setting<ReceiverAddress?>(
        "receiver.address", title: "Receiver Address", default: nil,
        "The receiver's IP address, used when the search finds no receiver, and only while it's"
            + " on the local network of an interface that's up. Null relies on the search alone.")
    public let appearance = Setting(
        "appearance", title: "Appearance", default: Appearance.auto,
        "Light or dark windows. Auto follows the system's setting as it changes.")

    public func conflicts(_ values: [String: any SettingValue]) -> [SettingConflict] {
        guard let sync = values[syncFolder.key] as? SyncFolder,
            let folders = values[watchedFolders.key] as? [WatchedFolder],
            let watched = folders.first(where: sync.isInside)
        else { return [] }
        return [
            SettingConflict(
                key: syncFolder.key,
                reason: "it's inside the watched folder \"\(watched.path)\"; the sync folder must"
                    + " be outside every watched folder, since the app writes its log there")
        ]
    }
}
