import LibraryBrowser
import Settings

/// Every setting and piece of app state the window reads, read in one place at launch and
/// passed in.
struct WindowSettings {
    var frame: WindowFrame?
    var sidebarWidth: Int
    var browserHeight: Int
    var sidebarVisible: Bool
    var statusBarVisible: Bool
    var queueVisible: Bool
    var queueWidth: Int
    var trackTable: TrackTableLayout
    var browser: BrowserState
    var folders: [WatchedFolder]

    init(_ settings: SettingsStore<AppSettings>, state: SettingsStore<AppState>) {
        frame = state[\.windowFrame]
        sidebarWidth = state[\.sidebarWidth]
        browserHeight = state[\.browserHeight]
        sidebarVisible = state[\.sidebarVisible]
        statusBarVisible = state[\.statusBarVisible]
        queueVisible = state[\.queueVisible]
        queueWidth = state[\.queueWidth]
        trackTable = state[\.trackTable]
        browser = BrowserState(
            source: state[\.source], genre: state[\.selectedGenre],
            artist: state[\.selectedArtist], album: state[\.selectedAlbum])
        folders = settings[\.watchedFolders]
    }
}
