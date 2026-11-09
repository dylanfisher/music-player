/// Where the user left things: the main window's layout and the browser's selections, saved as
/// they change to `state.json`. Not preferences, so not in the config file. The app reads these
/// once, at launch.
public struct AppState: SettingsSchema {
    public init() {}

    public let windowFrame = Setting<WindowFrame?>(
        "window.frame", title: "Window Frame", default: nil,
        "Where the main window was. Null centers it.")
    public let windowFrames = Setting(
        "window.frames", title: "Window Frames", default: WindowFrames(),
        "Where each other window was, by name. A window not listed opens centered on the main"
            + " window's screen.")
    /// What the window's sizes accept, in points, so the window never saves one that won't load.
    public static let sidebarWidthRange = 100...600
    public static let browserHeightRange = 0...2000
    /// The Listening Stats panel's header and its first row of cards, the Totals, fit in the
    /// least height.
    public static let statsHeightRange = 130...2000
    public static let queueWidthRange = 150...1000
    public let sidebarWidth = Setting(
        "window.sidebarWidth", title: "Sidebar Width", default: 180, range: sidebarWidthRange,
        "Width of the sidebar, in points.")
    public let browserHeight = Setting(
        "window.browserHeight", title: "Browser Height", default: 160,
        range: browserHeightRange,
        "Height of the browser's columns above the track table, in points. 0 hides"
            + " them.")
    public let statsHeight = Setting(
        "window.statsHeight", title: "Listening Stats Height", default: 380,
        range: statsHeightRange,
        "Height of the Listening Stats panel above the track table, in points.")
    public let browserVisible = Setting(
        "window.browserVisible", title: "Show Browser", default: true,
        "Show the browser's columns above the track table.")
    public let sidebarVisible = Setting(
        "window.sidebarVisible", title: "Show Sidebar", default: true,
        "Show the sidebar beside the browser.")
    public let toolbarVisible = Setting(
        "window.toolbarVisible", title: "Show Toolbar", default: true,
        "Show the toolbar above the browser.")
    public let statusBarVisible = Setting(
        "window.statusBarVisible", title: "Show Status Bar", default: true,
        "Show the status line under the track table.")
    public let statusTotals = Setting(
        "window.statusTotals", title: "Status Bar Totals", default: StatusTotals.listAndSelection,
        "Which totals the status bar shows: the list's and the selection's, the list's, or the"
            + " selection's, which falls back to the list's while nothing is selected.")
    public let queueVisible = Setting(
        "window.queueVisible", title: "Show Queue", default: false,
        "Show the queue beside the track table.")
    public let signalPathVisible = Setting(
        "window.signalPathVisible", title: "Show Signal Path", default: false,
        "Show what happens to the samples between the file and the device, under the"
            + " now-playing bar.")
    public let toolbarItems = Setting(
        "window.toolbarItems", title: "Toolbar Items", items: ToolbarItem.defaultItems,
        "The items in the main window's toolbar, left to right.")
    public let askedForAccessibility = Setting(
        "receiver.askedForAccessibility", title: "Asked for Accessibility", default: false,
        "Whether the system's Accessibility prompt was shown for the volume keys.")
    public let queueWidth = Setting(
        "window.queueWidth", title: "Queue Width", default: 220, range: queueWidthRange,
        "Width of the queue, in points.")
    public let trackTable = Setting(
        "browser.trackTable", title: "Track Table",
        default: TrackTableLayout(
            // About 820 points with spacing, which fits beside the sidebar and the queue in the
            // default window, itself smaller than a 1440 by 900 screen. Format, rate and depth
            // are in the header's menu.
            columns: [
                ColumnLayout(column: .title, width: 220), ColumnLayout(column: .artist, width: 150),
                ColumnLayout(column: .album, width: 170),
                ColumnLayout(column: .trackNumber, width: 44),
                ColumnLayout(column: .duration, width: 50), ColumnLayout(column: .year, width: 44),
                ColumnLayout(column: .genre, width: 100),
            ], sortColumn: .artist, sortAscending: true),
        "The track table's columns, left to right, with their widths, and the column it sorts by.")
    public let timelineTable = Setting<TimelineLayout?>(
        "browser.timelineTable", title: "Timeline Columns", default: nil,
        "The timeline's columns after Played, with their widths, once changed in the timeline."
            + " Null shows the track table's.")
    public let sourceSort = Setting<SourceSort?>(
        "browser.sourceSort", title: "Source Sort", default: nil,
        "The sort chosen in the source shown, when it's one that opens in a sort of its own: a"
            + " manual playlist, History or Listening Stats. Null for its own.")
    public let search = Setting(
        "browser.search", title: "Search Text", default: "",
        "The text in the search field, which narrows the track table. Empty for none.")
    public let browserColumns = Setting(
        "browser.columns", title: "Browser Columns", columns: BrowserColumn.defaults,
        "The browser's three columns, left to right: what each grouped by, and the entry"
            + " selected in it by name. A null selection is All. The config's"
            + " browser.columnGroupings, when it names them, says what the columns group by,"
            + " and a selection in a column it groups otherwise is dropped.")
    public let palettePlace = Setting<PalettePlace?>(
        "palette.place", title: "Palette Place", default: nil,
        "Where the palette was dragged. Null opens it centered near the top of the screen.")
    public let infoPlace = Setting<InfoWindowPlace?>(
        "tagEditor.place", title: "Get Info Place", default: nil,
        "Where a Get Info window was last moved to. Null opens it near the main window's top"
            + " left.")
    public let taggerSheets = Setting(
        "discogsTagger.sheets", title: "Discogs Tagger Sheets", default: TaggerSheetLayouts(),
        "The size, column widths and sort each of the Discogs tagger's sheets was left at.")
    public let taggerSource = Setting<DiscogsSource?>(
        "discogsTagger.source", title: "Discogs Tagger Source", default: nil,
        "Where the Discogs tagger last looked releases up on this Mac. Null asks the catalog"
            + " when there is one, else the Discogs API.")
    public let deviceProfiles = Setting(
        "output.profiles", title: "Device Profiles", default: DeviceProfiles(profiles: []),
        "Each output device's hog mode, digital volume and volume, and the rates and formats it"
            + " reported, most recently used first.")
    public let paletteVisits = Setting(
        "palette.visits", title: "Palette Visits", default: VisitLog(visits: []),
        "How often and how recently each palette item was chosen or played.")
}
