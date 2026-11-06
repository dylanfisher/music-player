import LibraryBrowser
import Settings

/// Every setting and piece of app state the window reads, read in one place at launch and
/// passed in.
struct WindowSettings {
    var frame: WindowFrame?
    var sidebarWidth: Int
    var browserHeight: Int
    var statsHeight: Int
    var sidebarVisible: Bool
    var browserVisible: Bool
    var statusBarVisible: Bool
    var toolbarVisible: Bool
    var statusTotals: StatusTotals
    var queueVisible: Bool
    var signalPathVisible: Bool
    var queueWidth: Int
    var trackTable: TrackTableLayout
    var timelineTable: TimelineLayout?
    var browser: BrowserState
    /// The play state saved at quit, whose source the window shows (ADR 0095).
    var resume: ResumePoint
    var groupByAlbumArtist: Bool
    var tableAppearance: TableAppearance
    var statusBar: StatusBarLayout
    var headerStatus: BarLayout<HeaderPart>
    var customStatuses: [ToolbarItem: BarLayout<HeaderPart>]
    var windowTitle: TitleTemplate
    var headerTitleFormat: TitleTemplate

    @MainActor init(_ settings: ConfigStore<AppSettings>, state: StateStore<AppState>) {
        frame = state[\.windowFrame]
        sidebarWidth = state[\.sidebarWidth]
        browserHeight = state[\.browserHeight]
        statsHeight = state[\.statsHeight]
        sidebarVisible = state[\.sidebarVisible]
        browserVisible = state[\.browserVisible]
        statusBarVisible = state[\.statusBarVisible]
        toolbarVisible = state[\.toolbarVisible]
        statusTotals = state[\.statusTotals]
        queueVisible = state[\.queueVisible]
        signalPathVisible = state[\.signalPathVisible]
        queueWidth = state[\.queueWidth]
        trackTable = state[\.trackTable]
        timelineTable = state[\.timelineTable]
        browser = BrowserState(
            source: nil,
            columns: BrowserColumn.restored(
                state[\.browserColumns], groupings: settings.fileValue(\.browserGroupings)))
        resume = settings[\.resume]
        groupByAlbumArtist = settings[\.groupByAlbumArtist]
        tableAppearance = TableAppearance(settings)
        statusBar = StatusBarLayout(settings)
        headerStatus = settings[\.headerStatusLayout]
        customStatuses = Dictionary(
            uniqueKeysWithValues: ToolbarItem.customStatuses.compactMap { item in
                item.customStatusSetting.map { (item, settings[$0]) }
            })
        windowTitle = settings[\.windowTitle]
        headerTitleFormat = settings[\.headerTitleFormat]
    }
}

extension StatusBarLayout {
    /// The settings' keys, whose change lays out the status bar again.
    static let keys = [AppSettings().statusBarLayout.key, AppSettings().statusBarStyle.key]

    @MainActor init(_ settings: ConfigStore<AppSettings>) {
        self.init(columns: settings[\.statusBarLayout], style: settings[\.statusBarStyle])
    }
}

extension TableAppearance {
    /// The settings' keys, whose change redraws the table.
    static let keys = [
        AppSettings().columnLines.key, AppSettings().rowLines.key, AppSettings().albumLines.key,
        AppSettings().rowLineColor.key, AppSettings().albumLineColor.key,
        AppSettings().playingRowColor.key,
        AppSettings().alternatingRows.key, AppSettings().rowHeight.key, AppSettings().artSize.key,
        AppSettings().glass.key,
    ]

    @MainActor init(_ settings: ConfigStore<AppSettings>) {
        self.init(
            columnLines: settings[\.columnLines], rowLines: settings[\.rowLines],
            albumLines: settings[\.albumLines], rowLineColor: settings[\.rowLineColor],
            albumLineColor: settings[\.albumLineColor],
            playingRowColor: settings[\.playingRowColor],
            alternatingRows: settings[\.alternatingRows], rowHeight: settings[\.rowHeight],
            artSize: settings[\.artSize], glass: settings[\.glass])
    }
}
