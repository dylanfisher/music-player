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

    // The main window's layout, saved as it changes. The app reads these once, at launch.
    public let windowFrame = Setting<WindowFrame?>(
        "window.frame", default: nil, "Where the main window was. Null centers it.")
    /// What the window's sizes accept, in points, so the window never saves one that won't load.
    public static let sidebarWidthRange = 100...600
    public static let browserHeightRange = 0...2000
    public static let queueWidthRange = 150...1000
    public let sidebarWidth = Setting(
        "window.sidebarWidth", default: 180, range: sidebarWidthRange,
        "Width of the sidebar, in points.")
    public let browserHeight = Setting(
        "window.browserHeight", default: 160, range: browserHeightRange,
        "Height of the genre, artist and album panes above the track table, in points. 0 hides"
            + " them.")
    public let queueVisible = Setting(
        "window.queueVisible", default: false, "Show the queue beside the track table.")
    public let queueWidth = Setting(
        "window.queueWidth", default: 220, range: queueWidthRange, "Width of the queue, in points.")
    public let trackTable = Setting(
        "browser.trackTable",
        default: TrackTableLayout(
            // About 810 points with spacing, which fits beside the sidebar and the queue in the
            // default window, itself smaller than a 1440 by 900 screen. Format, rate and depth
            // are in the header's menu.
            columns: [
                ColumnLayout(column: .title, width: 220), ColumnLayout(column: .artist, width: 150),
                ColumnLayout(column: .album, width: 170),
                ColumnLayout(column: .trackNumber, width: 34),
                ColumnLayout(column: .duration, width: 50), ColumnLayout(column: .year, width: 44),
                ColumnLayout(column: .genre, width: 100),
            ], sortColumn: .artist, sortAscending: true),
        "The track table's columns, left to right, with their widths, and the column it sorts by.")
    public let source = Setting<String?>(
        "browser.source", default: nil,
        "The watched folder the sidebar shows, by path. Null shows the whole library.")
    public let selectedGenre = Setting<String?>(
        "browser.genre", default: nil, "The genre selected in the browser. Null is All.")
    public let selectedArtist = Setting<String?>(
        "browser.artist", default: nil, "The artist selected in the browser. Null is All.")
    public let selectedAlbum = Setting<String?>(
        "browser.album", default: nil, "The album selected in the browser. Null is All.")
}
