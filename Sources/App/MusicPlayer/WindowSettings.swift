import LibraryBrowser
import Settings

/// Every setting the window reads, read in one place at launch and passed in.
struct WindowSettings {
    var frame: WindowFrame?
    var sidebarWidth: Int
    var browserHeight: Int
    var queueVisible: Bool
    var queueWidth: Int
    var trackTable: TrackTableLayout
    var browser: BrowserState
    var folders: [WatchedFolder]

    init(_ settings: SettingsStore<AppSettings>) {
        frame = settings[\.windowFrame]
        sidebarWidth = settings[\.sidebarWidth]
        browserHeight = settings[\.browserHeight]
        queueVisible = settings[\.queueVisible]
        queueWidth = settings[\.queueWidth]
        trackTable = settings[\.trackTable]
        browser = BrowserState(
            source: settings[\.source], genre: settings[\.selectedGenre],
            artist: settings[\.selectedArtist], album: settings[\.selectedAlbum])
        folders = settings[\.watchedFolders]
    }
}
