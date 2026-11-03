import LibraryBrowser
import Settings

/// Every setting and piece of app state the window reads, read in one place at launch and
/// passed in.
struct WindowSettings {
    var frame: WindowFrame?
    var sidebarWidth: Int
    var browserHeight: Int
    var sidebarVisible: Bool
    var browserVisible: Bool
    var statusBarVisible: Bool
    var statusTotals: StatusTotals
    var queueVisible: Bool
    var signalPathVisible: Bool
    var queueWidth: Int
    var trackTable: TrackTableLayout
    var browser: BrowserState
    var groupByAlbumArtist: Bool
    var tableAppearance: TableAppearance
    var statusBar: StatusBarLayout

    @MainActor init(_ settings: ConfigStore<AppSettings>, state: StateStore<AppState>) {
        frame = state[\.windowFrame]
        sidebarWidth = state[\.sidebarWidth]
        browserHeight = state[\.browserHeight]
        sidebarVisible = state[\.sidebarVisible]
        browserVisible = state[\.browserVisible]
        statusBarVisible = state[\.statusBarVisible]
        statusTotals = state[\.statusTotals]
        queueVisible = state[\.queueVisible]
        signalPathVisible = state[\.signalPathVisible]
        queueWidth = state[\.queueWidth]
        trackTable = state[\.trackTable]
        browser = BrowserState(
            source: state[\.source], genre: state[\.selectedGenre],
            artist: state[\.selectedArtist], album: state[\.selectedAlbum])
        groupByAlbumArtist = settings[\.groupByAlbumArtist]
        tableAppearance = TableAppearance(settings)
        statusBar = StatusBarLayout(settings)
    }
}

extension StatusBarLayout {
    /// The settings' keys, whose change lays out the status bar again.
    static let keys = [AppSettings().statusBarParts.key, AppSettings().statusBarStyle.key]

    @MainActor init(_ settings: ConfigStore<AppSettings>) {
        self.init(parts: settings[\.statusBarParts], style: settings[\.statusBarStyle])
    }
}

extension TableAppearance {
    /// The settings' keys, whose change redraws the table.
    static let keys = [
        AppSettings().columnLines.key, AppSettings().rowLines.key,
        AppSettings().alternatingRows.key, AppSettings().rowHeight.key, AppSettings().artSize.key,
    ]

    @MainActor init(_ settings: ConfigStore<AppSettings>) {
        self.init(
            columnLines: settings[\.columnLines], rowLines: settings[\.rowLines],
            alternatingRows: settings[\.alternatingRows], rowHeight: settings[\.rowHeight],
            artSize: settings[\.artSize])
    }
}
