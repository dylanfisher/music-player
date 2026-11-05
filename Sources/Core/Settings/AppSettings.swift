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
    public let resume = Setting(
        "playback.resume", title: "Play State", default: ResumePoint(),
        "The track, place and window at quit, which launch puts back paused.")
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
        "receiver.enabled", title: "Control the Receiver with the Volume Keys", default: false,
        "While the Denon receiver is connected, the volume keys set its volume.")
    public let receiverAddress = Setting<ReceiverAddress?>(
        "receiver.address", title: "Receiver Address", default: nil,
        "Only for when the search can't find the receiver: its IP address.")
    public let appearance = Setting(
        "appearance", title: "Appearance", default: Appearance.auto,
        "Light or dark windows; Auto follows the system.")
    public let columnLines = Setting(
        "appearance.columnLines", title: "Column Lines", default: false,
        "Draw a thin line between the track table's columns.")
    public let rowLines = Setting(
        "appearance.rowLines", title: "Row Lines", default: false,
        "Draw a thin line between the track table's rows.")
    public let albumLines = Setting(
        "appearance.albumLines", title: "Album Lines", default: false,
        "Draw a line where one album ends and the next begins.")
    public let rowLineColor = Setting<HexColor?>(
        "appearance.rowLineColor", title: "Row Line Color", default: nil,
        "The row and column lines' color; none uses the system's grid color.")
    public let albumLineColor = Setting<HexColor?>(
        "appearance.albumLineColor", title: "Album Line Color", default: nil,
        "The album lines' color; none uses the system's grid color.")
    public let playingRowColor = Setting<HexColor?>(
        "appearance.playingRowColor", title: "Playing Row Color", default: nil,
        "The playing track's row color; none uses a light gray.")
    public let alternatingRows = Setting(
        "appearance.alternatingRows", title: "Alternating Rows", default: true,
        "Shade every other row of the track table.")
    public let rowHeight = Setting(
        "appearance.rowHeight", title: "Row Height", default: RowHeight.regular,
        "How tall the track table's rows are.")
    public let artSize = Setting(
        "appearance.artSize", title: "Album Art", default: ArtSize.fit,
        "Art scaled to its album's rows, or always the column's width.")
    public let glass = Setting(
        "appearance.glass", title: "Window Glass", default: false,
        "Turns the whole player into translucent glass, with the desktop showing through.")
    public let windowTitle = Setting(
        "appearance.windowTitle", title: "Window Title", default: TitleTemplate.windowTitle,
        "The window's title, with the playing track's fields in braces.")
    public let headerStatusLayout = Setting(
        "appearance.headerStatusLayout", title: "Toolbar Status Layout",
        default: BarLayout.defaultHeaderStatus,
        "What the toolbar's now-playing status shows, in columns that stack their parts.")
    public let customStatus1Layout = Setting(
        "appearance.customStatus1Layout", title: ToolbarItem.customStatusTitle(1) + " Layout",
        default: BarLayout.defaultCustomStatus,
        "What the toolbar's Custom Status 1 item shows, in columns of parts.")
    public let customStatus2Layout = Setting(
        "appearance.customStatus2Layout", title: ToolbarItem.customStatusTitle(2) + " Layout",
        default: BarLayout.defaultCustomStatus,
        "What the toolbar's Custom Status 2 item shows, in columns of parts.")
    public let customStatus3Layout = Setting(
        "appearance.customStatus3Layout", title: ToolbarItem.customStatusTitle(3) + " Layout",
        default: BarLayout.defaultCustomStatus,
        "What the toolbar's Custom Status 3 item shows, in columns of parts.")
    public let headerTitleFormat = Setting(
        "appearance.headerTitleFormat", title: "Toolbar Title Line",
        default: TitleTemplate.titleLine,
        "The Title Line's text, with the playing track's fields in braces.")
    public let statusBarStyle = Setting(
        "appearance.statusBarStyle", title: "Status Bar", default: StatusBarStyle.minimal,
        "One line at the header's height, or two with larger art.")
    public let statusBarLayout = Setting(
        "appearance.statusBarLayout", title: "Status Bar Layout",
        default: BarLayout.defaultStatusBar,
        "What the status bar shows, in columns around its centered middle.")

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
