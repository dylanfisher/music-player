/// Every setting the app has.
public struct AppSettings: SettingsSchema {
    public init() {}

    public let outputDeviceUID = Setting<String?>(
        "output.deviceUID", title: "Output Device", default: nil,
        "The device to play through; none uses the system default.")
    public let hogMode = Setting(
        "output.hogMode", title: "Hog Mode", default: true,
        "Keep other apps off the output device while playing.")
    public let digitalVolume = Setting(
        "output.digitalVolume", title: "Digital Volume", default: false,
        "Let the app lower the volume, which ends bit-perfect output.")
    public let playedPercent = Setting(
        "playback.playedPercent", title: "Count as Played At", default: 75, range: 1...100,
        "The percent of a track that must play to count as played.")
    public let outputRenderer = Setting<String?>(
        "output.renderer", title: "Network Renderer", default: nil,
        "The UPnP renderer to play to, by UDN; none uses the device.")
    public let watchedFolders = Setting<[WatchedFolder]>(
        "library.watchedFolders", title: "Watched Folders", default: [],
        "Folders the library scans and watches for changes.")
    public let pausePollingDuringPlayback = Setting(
        "library.pausePollingDuringPlayback", title: "Pause Network Rescans While Playing",
        default: false,
        "Don't rescan network folders while music is playing.")
    public let rescanNetworkFoldersAtLaunch = Setting(
        "library.rescanNetworkFoldersAtLaunch", title: "Rescan Network Folders at Launch",
        default: false,
        "Rescan every network folder when the app starts.")
    /// What `networkScanReaders` and `--scan --readers` accept; a scan starts that many threads.
    public static let networkScanReadersRange = 1...64
    public let networkScanReaders = Setting<Int?>(
        "library.networkScanReaders", title: "Network Scan Readers", default: nil,
        range: networkScanReadersRange,
        "Files a network scan reads at once; none tunes it automatically.")
    public let syncFolder = Setting<SyncFolder?>(
        "sync.folder", title: "Sync Folder", default: nil,
        "A folder outside your music where your Macs share plays and ratings.")
    public let groupByAlbumArtist = Setting(
        "library.groupByAlbumArtist", title: "Group by Album Artist", default: true,
        "List album artists, not every track artist, in the Artist pane.")
    public let fileViewer = Setting(
        "library.fileViewer", title: "File Viewer", default: FileViewer.searcher,
        "Where Reveal in Finder shows tracks; without Searcher, it uses Finder.")
    public let receiverEnabled = Setting(
        "receiver.enabled", title: "Receiver Control", default: false,
        "Control a Denon receiver's volume, input and power over the network.")
    public let receiverAddress = Setting<ReceiverAddress?>(
        "receiver.address", title: "Receiver Address", default: nil,
        "The receiver's IP address, for when the search can't find it.")
    public let receiverVolumeKeys = Setting(
        "receiver.volumeKeys", title: "Volume Keys Control the Receiver", default: true,
        "Volume keys set the receiver's volume; needs Accessibility permission.")
    public let appearance = Setting(
        "appearance", title: "Appearance", default: Appearance.auto,
        "Light or dark windows; Auto follows the system.")
    public let columnLines = Setting(
        "appearance.columnLines", title: "Column Lines", default: false,
        "Draw a thin line between the track table's columns.")
    public let rowLines = Setting(
        "appearance.rowLines", title: "Row Lines", default: false,
        "Draw a thin line between the track table's rows.")
    public let alternatingRows = Setting(
        "appearance.alternatingRows", title: "Alternating Rows", default: true,
        "Shade every other row of the track table.")
    public let rowHeight = Setting(
        "appearance.rowHeight", title: "Row Height", default: RowHeight.regular,
        "How tall the track table's rows are.")
    public let artSize = Setting(
        "appearance.artSize", title: "Album Art", default: ArtSize.fit,
        "Art scaled to its album's rows, or always the column's width.")
    public let statusBarStyle = Setting(
        "appearance.statusBarStyle", title: "Status Bar", default: StatusBarStyle.minimal,
        "One line at the header's height, or two with larger art.")
    public let statusBarParts = Setting(
        "appearance.statusBarParts", title: "Status Bar Items", parts: [StatusPart.totals],
        "What the status bar shows, left to right; drag to reorder.")

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
