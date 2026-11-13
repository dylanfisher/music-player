/// Every setting the app has.
public struct AppSettings: SettingsSchema {
    public init() {}

    public let outputDeviceUID = Setting<String?>(
        "output.deviceUID", title: "Output Device", default: nil,
        "The device to play through; none uses the system default.")
    public let hogMode = Setting(
        "output.hogMode", title: "Hog Mode", default: false,
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
    public let removeMissingTracks = Setting(
        "library.removeMissingTracks", title: "Remove Missing Tracks", default: true,
        "Drop a track when its file leaves a watched folder; files stay.")
    public let rescanModifiedFiles = Setting(
        "library.rescanModifiedFiles", title: "Rescan Modified Files", default: true,
        "Read a file's tags again when it changes in a watched folder.")
    public let pausePollingDuringPlayback = Setting(
        "library.pausePollingDuringPlayback", title: "Pause Network Rescans While Playing",
        default: false,
        "Don't rescan network folders while music is playing.")
    public let rescanNetworkFoldersAtLaunch = Setting(
        "library.rescanNetworkFoldersAtLaunch", title: "Rescan Network Folders at Launch",
        default: false,
        "Rescan every network folder when the app starts.")
    public let copyAddedFiles = Setting(
        "library.copyAddedFiles", title: "Copy Added Files into the Library Folder",
        default: false,
        "Files dropped on the window are copied in, by artist and album.")
    public let keepFilesOrganized = Setting(
        "library.keepFilesOrganized", title: "Keep Files Organized", default: false,
        "Tag edits rename files in the library folder by artist and album.")
    public let libraryFolder = Setting<String?>(
        "library.folder", title: "Library Folder", default: nil,
        "Where added files are copied; it's watched once they are.")
    public let snapshotFolder = Setting<String?>(
        "library.snapshotFolder", title: "Snapshot Folder", default: nil,
        "A local folder outside your music for daily snapshots; none uses Backups.")
    /// What `networkScanReaders` and `--scan --readers` accept; a scan starts that many threads.
    public static let networkScanReadersRange = 1...64
    public let networkScanReaders = Setting<Int?>(
        "library.networkScanReaders", title: "Network Scan Readers", default: nil,
        range: networkScanReadersRange,
        "Files a network scan reads at once; none tunes it automatically.")
    public let syncFolder = Setting<SyncFolder?>(
        "sync.folder", title: "Sync Folder", default: nil,
        "A folder outside your music where your Macs share plays and ratings.")
    public let discogsDumpsFolder = Setting<DumpsFolder?>(
        "discogs.dumpsFolder", title: "Discogs Dumps Folder", default: nil,
        "The folder of Discogs's monthly dumps, read to build the catalog.")
    public let discogsCatalogPath = Setting<String?>(
        "discogs.catalogPath", title: "Discogs Catalog", filePath: nil,
        "The catalog's file, outside your music; none keeps it with the library.")
    public let discogsToken = Setting<DiscogsToken?>(
        "discogs.token", title: "Discogs Token", default: nil,
        "A personal access token from discogs.com/settings/developers, for the API.")
    public let discogsMapping = Setting(
        "discogs.mapping", title: "Discogs Field Mapping", default: DiscogsPreset.oneToOne.mapping,
        "Where the Discogs tagger writes each field, and how.")
    public let discogsSavedMappings = Setting<[NamedDiscogsMapping]>(
        "discogs.savedMappings", title: "Saved Discogs Mappings", default: [],
        "Field mappings saved by name, beside the presets.")
    public let discogsKeepExistingValues = Setting(
        "discogs.keepExistingValues", title: "Keep Existing Values", default: false,
        "The Discogs tagger fills titles, numbers, credits and dates only where empty.")
    public let discogsSkipVideo = Setting(
        "discogs.skipVideo", title: "Skip Blu-ray, DVD and Video", default: true,
        "The Discogs tagger never matches a release that is only video.")
    public let discogsFillSortArtist = Setting(
        "discogs.fillSortArtist", title: "Fill Sort Artist from Album Artist", default: false,
        "The Discogs tagger gives files without a sort artist the album artist.")
    public let recommenderAddress = Setting<IPAddressSetting?>(
        "recommender.address", title: "Service Address", default: nil,
        "The IP address of the Mac running music-recommender; host names aren't taken.")
    public let recommenderPort = Setting(
        "recommender.port", title: "Service Port", default: 7878, range: 1...65535,
        "The port music-recommender's API listens on.")
    public let recommenderToken = Setting<ServiceToken?>(
        "recommender.token", title: "Service Token", default: nil,
        "The token music-recommender's config holds as player_token, kept in this file only.")
    public let stagingFolder = Setting<StagingFolder?>(
        "import.stagingFolder", title: "Staging Folder", default: nil,
        "Where music-recommender puts downloads for review, outside your music folders.")
    public let autoApproveSafeMatches = Setting(
        "import.autoApproveSafeMatches", title: "Approve Safe Matches Automatically",
        default: false,
        "Approve clean downloads that leave nothing to review.")
    public let autoUpgrade = Setting(
        "downloads.autoUpgrade", title: "Upgrade to FLAC Automatically", default: false,
        "Download FLAC copies of the most-played lossy albums while open.")
    public let autoUpgradesInFlight = Setting(
        "downloads.autoUpgradesInFlight", title: "Upgrades at Once", default: 3,
        range: 1...10, "How many automatic upgrades music-recommender works on at a time.")
    public let discogsArtwork = Setting(
        "discogs.artwork", title: "Discogs Artwork", default: DiscogsArtworkMode.off,
        "The Discogs tagger writes the release's cover: never, where none, or always.")
    public let groupByAlbumArtist = Setting(
        "library.groupByAlbumArtist", title: "Group by Album Artist", default: true,
        "List album artists, not every track artist, in the Artist pane.")
    public let separateReleases = Setting(
        "library.separateReleases", title: "Separate Releases", default: false,
        "Make each Discogs release an album, apart from same-titled reissues.")
    public let browserGroupings = Setting(
        "browser.columnGroupings", title: "Browser Column Groupings",
        groupings: BrowserColumn.defaults.map(\.grouping),
        "Each browser column's grouping, left to right; right-click a header to change.")
    public let showRediscover = Setting(
        "library.showRediscover", title: "Show Rediscover in Sidebar", default: true,
        "List Rediscover in the sidebar; Show Rediscover opens it either way.")
    public let fileViewer = Setting(
        "library.fileViewer", title: "File Viewer", default: FileViewer.searcher,
        "Where Reveal in Finder shows tracks; without Searcher, it uses Finder.")
    public let receiverEnabled = Setting(
        "receiver.enabled", title: "Control the Receiver with the Volume Keys", default: false,
        "The volume keys set a connected Denon or Marantz receiver's volume.")
    public let receiverAddress = Setting<IPAddressSetting?>(
        "receiver.address", title: "Receiver Address", default: nil,
        "Its IP address: for a Marantz, or a Denon the search misses.")
    public let appearance = Setting(
        "appearance", title: "Appearance", default: Appearance.auto,
        "Light or dark windows; Auto follows the system.")
    public let columnLines = Setting(
        "appearance.columnLines", title: "Column Lines", default: false,
        "A thin line between the columns.")
    public let rowLines = Setting(
        "appearance.rowLines", title: "Row Lines", default: false,
        "A thin line between the rows.")
    public let albumLines = Setting(
        "appearance.albumLines", title: "Album Lines", default: false,
        "A line where one album ends and the next begins.")
    public let rowLineColor = Setting<HexColor?>(
        "appearance.rowLineColor", title: "Row Line Color", default: nil,
        "Colors the column lines too; Default is the system's grid color.")
    public let albumLineColor = Setting<HexColor?>(
        "appearance.albumLineColor", title: "Album Line Color", default: nil,
        "Default is the system's grid color.")
    public let playingRowColor = Setting<HexColor?>(
        "appearance.playingRowColor", title: "Playing Row Color", default: nil,
        "Default is a light gray.")
    public let alternatingRows = Setting(
        "appearance.alternatingRows", title: "Alternating Rows", default: true,
        "Shade every other row.")
    public let rowHeight = Setting(
        "appearance.rowHeight", title: "Row Height", default: RowHeight.regular,
        "Compact fits more tracks; Large is easier to read.")
    public let artSize = Setting(
        "appearance.artSize", title: "Album Art", default: ArtSize.fit,
        "Scaled to its album's rows, or always the column's width.")
    public let focusFontSize = Setting(
        "appearance.focusFontSize", title: "Focus Mode Text Size", default: 30, range: 16...96,
        "Focus Mode's text size, in points; its rows grow to fit.")
    public let glass = Setting(
        "appearance.glass", title: "Window Glass", default: false,
        "Translucent windows, with the desktop showing through.")
    public let windowTitle = Setting(
        "appearance.windowTitle", title: "Window Title", default: TitleTemplate.windowTitle,
        "The playing track's fields go in braces.")
    public let headerStatusLayout = Setting(
        "appearance.headerStatusLayout", title: "Toolbar Status Layout",
        default: BarLayout.defaultHeaderStatus,
        "What the toolbar's Now Playing item shows.")
    public let customStatus1Layout = Setting(
        "appearance.customStatus1Layout", title: ToolbarItem.customStatusTitle(1) + " Layout",
        default: BarLayout.defaultCustomStatus,
        "What the toolbar's Custom Status 1 item shows.")
    public let customStatus2Layout = Setting(
        "appearance.customStatus2Layout", title: ToolbarItem.customStatusTitle(2) + " Layout",
        default: BarLayout.defaultCustomStatus,
        "What the toolbar's Custom Status 2 item shows.")
    public let customStatus3Layout = Setting(
        "appearance.customStatus3Layout", title: ToolbarItem.customStatusTitle(3) + " Layout",
        default: BarLayout.defaultCustomStatus,
        "What the toolbar's Custom Status 3 item shows.")
    /// The Custom Status items' layouts, in `ToolbarItem.customStatuses`' order.
    public var customStatusLayouts: [Setting<BarLayout<HeaderPart>>] {
        [customStatus1Layout, customStatus2Layout, customStatus3Layout]
    }
    public let headerTitleFormat = Setting(
        "appearance.headerTitleFormat", title: "Toolbar Title Line",
        default: TitleTemplate.titleLine,
        "The Title Line part's text; fields go in braces.")
    public let statusBarStyle = Setting(
        "appearance.statusBarStyle", title: "Status Bar", default: StatusBarStyle.minimal,
        "One line at the header's height, or two with larger art.")
    public let statusBarLayout = Setting(
        "appearance.statusBarLayout", title: "Status Bar Layout",
        default: BarLayout.defaultStatusBar,
        "What the status bar shows, around its centered middle.")
    public let totalsFormat = Setting(
        "appearance.totalsFormat", title: "Totals, Nothing Selected",
        default: TotalsTemplate.nothingSelected,
        "The status bar's totals while nothing is selected; totals go in braces.")
    public let totalsListAndSelectionFormat = Setting(
        "appearance.totalsListAndSelectionFormat",
        title: "Totals, " + StatusTotals.listAndSelection.title,
        default: TotalsTemplate.shown(.listAndSelection),
        "With tracks selected, when a click on the totals chose both.")
    public let totalsListFormat = Setting(
        "appearance.totalsListFormat", title: "Totals, " + StatusTotals.list.title,
        default: TotalsTemplate.shown(.list),
        "With tracks selected, when a click on the totals chose the list's.")
    public let totalsSelectionFormat = Setting(
        "appearance.totalsSelectionFormat", title: "Totals, " + StatusTotals.selection.title,
        default: TotalsTemplate.shown(.selection),
        "With tracks selected, when a click on the totals chose the selection's.")
    public let downloadsStatusStyle = Setting(
        "appearance.downloadsStatusStyle", title: "Download Status",
        default: DownloadsStatusStyle.progress,
        "While albums download, the status bar's right end shows them.")

    public func conflicts(_ values: [String: any SettingValue]) -> [SettingConflict] {
        let folders = values[watchedFolders.key] as? [WatchedFolder] ?? []
        var conflicts: [SettingConflict] = []
        if let sync = values[syncFolder.key] as? SyncFolder,
            let watched = folders.first(where: sync.isInside)
        {
            conflicts.append(
                SettingConflict(
                    key: syncFolder.key,
                    reason: insideWatchedReason(
                        watched, "the sync folder", "the app writes its log there")))
        }
        if let catalog = values[discogsCatalogPath.key] as? String,
            let watched = watchedFolder(holding: catalog, among: folders)
        {
            conflicts.append(
                SettingConflict(
                    key: discogsCatalogPath.key,
                    reason: insideWatchedReason(watched, "the catalog", "the app writes it")))
        }
        if let snapshots = values[snapshotFolder.key] as? String {
            if let watched = watchedFolder(holding: snapshots, among: folders) {
                conflicts.append(
                    SettingConflict(
                        key: snapshotFolder.key,
                        reason: insideWatchedReason(
                            watched, "the snapshot folder",
                            "the app writes the library's snapshots there")))
            } else if let sync = values[syncFolder.key] as? SyncFolder, sync.share == nil,
                isPath(standardized(snapshots), inOrAt: standardized(sync.path))
            {
                conflicts.append(
                    SettingConflict(
                        key: snapshotFolder.key,
                        reason: "it's inside the sync folder \"\(sync.path)\"; the app writes only"
                            + " its own log there"))
            }
        }
        if let staging = values[stagingFolder.key] as? StagingFolder {
            var others = folders.map { (path: $0.path, share: $0.share) }
            for key in [libraryFolder.key, snapshotFolder.key] {
                if let path = values[key] as? String { others.append((path: path, share: nil)) }
            }
            if let sync = values[syncFolder.key] as? SyncFolder {
                others.append((path: sync.path, share: sync.share))
            }
            if let other = staging.overlap(others) {
                conflicts.append(
                    SettingConflict(
                        key: stagingFolder.key,
                        reason: "it overlaps \"\(other)\"; the staging folder must be apart from"
                            + " the watched, library, sync and snapshot folders, since the service"
                            + " deletes in it and the app moves files out of it"))
            }
        }
        return conflicts
    }

    /// The folder among `folders` stored by path that `path` is in or is.
    private func watchedFolder(holding path: String, among folders: [WatchedFolder])
        -> WatchedFolder?
    {
        folders.first {
            $0.share == nil && isPath(standardized(path), inOrAt: standardized($0.path))
        }
    }

    /// Why `subject` can't be inside `watched`: the app writes there, `why`.
    private func insideWatchedReason(_ watched: WatchedFolder, _ subject: String, _ why: String)
        -> String
    {
        "it's inside the watched folder \"\(watched.path)\"; \(subject) must be outside every"
            + " watched folder, since \(why)"
    }
}
