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
    var queueVisible: Bool
    var signalPathVisible: Bool
    var queueWidth: Int
    var trackTable: TrackTableLayout
    var browser: BrowserState
    var groupByAlbumArtist: Bool

    @MainActor init(_ settings: ConfigStore<AppSettings>, state: StateStore<AppState>) {
        frame = state[\.windowFrame]
        sidebarWidth = state[\.sidebarWidth]
        browserHeight = state[\.browserHeight]
        sidebarVisible = state[\.sidebarVisible]
        browserVisible = state[\.browserVisible]
        statusBarVisible = state[\.statusBarVisible]
        queueVisible = state[\.queueVisible]
        signalPathVisible = state[\.signalPathVisible]
        queueWidth = state[\.queueWidth]
        trackTable = state[\.trackTable]
        browser = BrowserState(
            source: state[\.source], genre: state[\.selectedGenre],
            artist: state[\.selectedArtist], album: state[\.selectedAlbum])
        groupByAlbumArtist = settings[\.groupByAlbumArtist]
    }
}
