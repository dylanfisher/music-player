/// Where the user left things: the main window's layout and the browser's selections, saved as
/// they change to `state.json`. Not preferences, so not in the config file. The app reads these
/// once, at launch.
public struct AppState: SettingsSchema {
    public init() {}

    public let windowFrame = Setting<WindowFrame?>(
        "window.frame", title: "Window Frame", default: nil,
        "Where the main window was. Null centers it.")
    /// What the window's sizes accept, in points, so the window never saves one that won't load.
    public static let sidebarWidthRange = 100...600
    public static let browserHeightRange = 0...2000
    public static let queueWidthRange = 150...1000
    public let sidebarWidth = Setting(
        "window.sidebarWidth", title: "Sidebar Width", default: 180, range: sidebarWidthRange,
        "Width of the sidebar, in points.")
    public let browserHeight = Setting(
        "window.browserHeight", title: "Browser Height", default: 160,
        range: browserHeightRange,
        "Height of the genre, artist and album panes above the track table, in points. 0 hides"
            + " them.")
    public let sidebarVisible = Setting(
        "window.sidebarVisible", title: "Show Sidebar", default: true,
        "Show the sidebar beside the browser.")
    public let statusBarVisible = Setting(
        "window.statusBarVisible", title: "Show Status Bar", default: true,
        "Show the status line under the track table.")
    public let queueVisible = Setting(
        "window.queueVisible", title: "Show Queue", default: false,
        "Show the queue beside the track table.")
    public let queueWidth = Setting(
        "window.queueWidth", title: "Queue Width", default: 220, range: queueWidthRange,
        "Width of the queue, in points.")
    public let trackTable = Setting(
        "browser.trackTable", title: "Track Table",
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
    public let source = Setting<BrowserSource?>(
        "browser.source", title: "Source", default: nil,
        "The watched folder, playlist or history the sidebar shows. Null shows the whole"
            + " library.")
    public let selectedGenre = Setting<String?>(
        "browser.genre", title: "Genre", default: nil,
        "The genre selected in the browser. Null is All.")
    public let selectedArtist = Setting<String?>(
        "browser.artist", title: "Artist", default: nil,
        "The artist selected in the browser. Null is All.")
    public let selectedAlbum = Setting<String?>(
        "browser.album", title: "Album", default: nil,
        "The album selected in the browser. Null is All.")
    public let palettePlace = Setting<PalettePlace?>(
        "palette.place", title: "Palette Place", default: nil,
        "Where the palette was dragged. Null opens it centered near the top of the screen.")
    public let paletteVisits = Setting(
        "palette.visits", title: "Palette Visits", default: VisitLog(visits: []),
        "How often and how recently each palette item was chosen or played.")
}
