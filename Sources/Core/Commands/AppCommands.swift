import DisplayText
import KeyChord
import Receiver
import Settings

extension CommandID {
    public static let showPalette = CommandID("window.showPalette")
    public static let goToItem = CommandID("window.goToItem")
    /// In Go to Item, filters the browser to the selected artist or album.
    public static let filterToItem = CommandID("palette.filterToItem")

    public static let selectNext = CommandID("selection.down")
    public static let selectPrevious = CommandID("selection.up")
    public static let extendDown = CommandID("selection.extendDown")
    public static let extendUp = CommandID("selection.extendUp")
    public static let tenRowsDown = CommandID("selection.tenRowsDown")
    public static let tenRowsUp = CommandID("selection.tenRowsUp")
    public static let extendTenRowsDown = CommandID("selection.extendTenRowsDown")
    public static let extendTenRowsUp = CommandID("selection.extendTenRowsUp")
    public static let nextAlbum = CommandID("selection.nextAlbum")
    public static let previousAlbum = CommandID("selection.previousAlbum")
    public static let extendToNextAlbum = CommandID("selection.extendToNextAlbum")
    public static let extendToPreviousAlbum = CommandID("selection.extendToPreviousAlbum")
    public static let selectFirst = CommandID("selection.first")
    public static let selectLast = CommandID("selection.last")
    public static let pageDown = CommandID("selection.pageDown")
    public static let pageUp = CommandID("selection.pageUp")
    public static let selectAll = CommandID("edit.selectAll")

    public static let find = CommandID("search.find")
    public static let sortByTitle = CommandID("sort.title")
    public static let sortByArtist = CommandID("sort.artist")
    public static let sortByAlbum = CommandID("sort.album")
    public static let sortByDateAdded = CommandID("sort.dateAdded")
    public static let reverseSort = CommandID("sort.reverse")

    public static let toggleSidebar = CommandID("view.toggleSidebar")
    public static let focusSidebar = CommandID("view.focusSidebar")
    public static let toggleStatusBar = CommandID("view.toggleStatusBar")
    public static let toggleToolbar = CommandID("view.toggleToolbar")
    /// Hides the toolbar, the sidebar and the status bar, then shows what showed.
    public static let distractionFree = CommandID("view.distractionFree")
    public static let toggleBrowser = CommandID("view.toggleBrowser")
    public static let toggleQueue = CommandID("view.toggleQueue")
    public static let toggleSignalPath = CommandID("view.toggleSignalPath")
    public static let showCurrentTrack = CommandID("view.showCurrentTrack")
    /// Centers the selected rows, as Show Current Track does the track playing.
    public static let showSelectedTrack = CommandID("view.showSelectedTrack")
    public static let showAllTracks = CommandID("view.showAllTracks")
    public static let scrollUp = CommandID("view.scrollUp")
    public static let scrollDown = CommandID("view.scrollDown")
    public static let back = CommandID("go.back")
    public static let forward = CommandID("go.forward")
    /// Steps back over the track table's selections, as Sublime Text's Undo Selection.
    public static let undoSelection = CommandID("go.undoSelection")
    public static let redoSelection = CommandID("go.redoSelection")
    public static let focusNextPane = CommandID("focus.nextPane")
    public static let focusPreviousPane = CommandID("focus.previousPane")
    public static let focusNextArea = CommandID("focus.nextArea")
    public static let focusPreviousArea = CommandID("focus.previousArea")

    public static let addFolder = CommandID("library.addFolder")
    public static let showWatchedFolders = CommandID("library.showWatchedFolders")
    /// Shows Library Health over the track table; the ID is the one it had as Check Library
    /// Health, so a saved shortcut still holds.
    public static let checkHealth = CommandID("library.checkHealth")
    /// Shows Listening Stats; `music-player stats` prints them (ADR 0102).
    public static let showStats = CommandID("library.stats")
    public static let showYearInReview = CommandID("library.yearInReview")
    /// Opens the Discogs tagger, which writes tags only after the user confirms (ADR 0133).
    public static let showDiscogsTagger = CommandID("library.discogsTagger")
    /// Opens the Downloads window: albums music-recommender found on Soulseek, staged for
    /// review, which reach the library only on Approve (ADR 0147).
    public static let showDownloads = CommandID("downloads.show")
    public static let rescanNow = CommandID("library.rescanNow")
    /// Analyzes every file not analyzed yet, or changed since, until paused (ADR 0116); once
    /// every file was tried, the whole library again (ADR 0119).
    public static let analyzeLibrary = CommandID("library.analyzeLibrary")
    public static let pauseLibraryAnalysis = CommandID("library.pauseAnalysis")
    /// Holds the running scan until Resume Scan, whatever playback does (ADR 0119).
    public static let pauseScan = CommandID("library.pauseScan")
    public static let resumeScan = CommandID("library.resumeScan")
    public static let resolveLostStats = CommandID("library.resolveLostStats")
    public static let restoreRemoved = CommandID("library.restoreRemoved")
    /// Applies a list of moved files' old and new paths to the index (ADR 0026).
    public static let importMoves = CommandID("library.importMoves")
    public static let revealInFinder = CommandID("track.revealInFinder")
    public static let copyPath = CommandID("track.copyPath")
    /// Removes the selection from the library, or moves its files to the Trash (ADR 0050).
    public static let removeTracks = CommandID("track.remove")
    public static let editTags = CommandID("track.editTags")
    /// Shows the selection's spectrum; `music-player analyze` prints its measures (ADR 0115).
    public static let showSpectrum = CommandID("track.analyze")
    public static let undoTagEdit = CommandID("track.undoTagEdit")
    public static let replaceArtwork = CommandID("tags.replaceArtwork")
    public static let removeArtwork = CommandID("tags.removeArtwork")
    public static let removeFromQueue = CommandID("queue.remove")
    public static let addToPlaylist = CommandID("playlist.addSelection")
    /// Like: the loved flag.
    public static let toggleLoved = CommandID("track.toggleLoved")
    public static let toggleDisliked = CommandID("track.toggleDisliked")
    public static let showAlbum = CommandID("track.showAlbum")
    public static let showArtist = CommandID("track.showArtist")
    public static let showInPlaylist = CommandID("track.showInPlaylist")
    public static let showInAllMusic = CommandID("track.showInAllMusic")
    public static let openDiscogsRelease = CommandID("track.openDiscogsRelease")
    /// Rate the selection 0 (no rating) to 5 stars, by index.
    public static let rate = (0...5).map { CommandID("track.rate\($0)") }

    public static let newPlaylist = CommandID("playlist.new")
    public static let newPlaylistFromSelection = CommandID("playlist.newFromSelection")
    public static let newSmartPlaylist = CommandID("playlist.newSmart")
    public static let editSmartPlaylist = CommandID("playlist.editRules")
    public static let renamePlaylist = CommandID("playlist.rename")
    public static let duplicatePlaylist = CommandID("playlist.duplicate")
    public static let deletePlaylist = CommandID("playlist.delete")
    public static let importPlaylist = CommandID("playlist.import")
    public static let exportPlaylist = CommandID("playlist.export")
    public static let importSwinsian = CommandID("library.importSwinsian")
    public static let importITunes = CommandID("library.importITunes")

    public static let playPause = CommandID("playback.playPause")
    public static let play = CommandID("playback.play")
    public static let pause = CommandID("playback.pause")
    public static let playSelection = CommandID("playback.playSelection")
    public static let playNext = CommandID("playback.playNext")
    public static let addToQueue = CommandID("playback.addToQueue")
    public static let nextTrack = CommandID("playback.next")
    public static let previousTrack = CommandID("playback.previous")
    public static let seekForward = CommandID("playback.seekForward")
    public static let seekBack = CommandID("playback.seekBack")
    /// Seek by `AppCommands.seekStepPercent` of the playing track's duration, or
    /// `AppCommands.seekStepMinimumSeconds`, whichever is longer.
    public static let seekForwardPercent = CommandID("playback.seekForwardPercent")
    public static let seekBackPercent = CommandID("playback.seekBackPercent")
    public static let volumeUp = CommandID("playback.volumeUp")
    public static let volumeDown = CommandID("playback.volumeDown")
    public static let stop = CommandID("playback.stop")
    public static let shuffle = CommandID("playback.shuffle")
    public static let repeatOff = CommandID("playback.repeatOff")
    public static let repeatAll = CommandID("playback.repeatAll")
    public static let repeatOne = CommandID("playback.repeatOne")

    // Their last parts differ from the app's own, as the command line names commands by them.
    public static let receiverVolumeUp = CommandID("receiver.raiseVolume")
    public static let receiverVolumeDown = CommandID("receiver.lowerVolume")
    public static let receiverSetVolume = CommandID("receiver.setVolume")
    public static let receiverMute = CommandID("receiver.mute")
    public static let receiverPowerOn = CommandID("receiver.powerOn")
    public static let receiverStandby = CommandID("receiver.standby")

    /// `receiver.modePureDirect`.
    public static func receiverSoundMode(_ mode: ReceiverSoundMode) -> CommandID {
        CommandID("receiver.mode" + capitalized("\(mode)"))
    }

    /// `receiver.inputBluRay`.
    public static func receiverInput(_ input: ReceiverInput) -> CommandID {
        CommandID("receiver.input" + capitalized("\(input)"))
    }

    private static func capitalized(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    public static let showSettings = CommandID("app.showSettings")
    public static let openConfigFile = CommandID("app.openConfigFile")
    public static let copyDefaultConfig = CommandID("app.copyDefaultConfig")
}

/// Every command the app has, defaults included. docs/decisions/0012 has the tables they come
/// from.
public enum AppCommands {
    private static let cmd: KeyChord.Modifiers = .command
    private static let shift: KeyChord.Modifiers = .shift
    private static let opt: KeyChord.Modifiers = .option
    private static let ctrl: KeyChord.Modifiers = .control
    /// The view toggles show and hide what these state entries save, under the same titles.
    private static let state = AppState()
    /// Play's argument: the search field's text, or a pane and an entry's name, as
    /// `PlayQuery` reads it.
    private static let playArgument = "a search, or album:, artist: or genre: and a name"
    /// Set Receiver Volume's argument, as `ReceiverVolume(decibels:)` reads it.
    private static let receiverVolumeArgument = "a level in dB from -80 to +18, in half steps"
    /// How far Seek Forward and Back 5% or 30 s move: this percentage of the track's duration,
    /// or `seekStepMinimumSeconds` when that's longer or the duration is unknown.
    public static let seekStepPercent = 5
    public static let seekStepMinimumSeconds = 30
    /// Show Listening Stats' argument, as `StatsPeriod(text:)` reads it.
    private static let statsPeriodArgument = StatsPeriod.textHelp
    /// Analyze Library's title once every file was tried, when it reads them all again.
    public static let analyzeLibraryAgainTitle = "Analyze Library Again…"

    /// The commands written here, without the ones generated from settings.
    static let fixedSet: [Command] =
        [
            Command(.showPalette, "Command Palette…", [.init("k", cmd)]),
            Command(.goToItem, "Go to Item…", [.init("p", cmd)]),
            Command(.filterToItem, "Filter to Item", [.init(.right)], palette: true),

            Command(.selectNext, "Select Next Row", [.init(.down)]),
            Command(.selectPrevious, "Select Previous Row", [.init(.up)]),
            Command(.extendDown, "Extend Selection Down", [.init(.down, shift)]),
            Command(.extendUp, "Extend Selection Up", [.init(.up, shift)]),
            Command(.tenRowsDown, "Move Down 10 Rows", [.init(.down, opt)]),
            Command(.tenRowsUp, "Move Up 10 Rows", [.init(.up, opt)]),
            Command(
                .extendTenRowsDown, "Extend Selection Down 10 Rows", [.init(.down, [opt, shift])]),
            Command(.extendTenRowsUp, "Extend Selection Up 10 Rows", [.init(.up, [opt, shift])]),
            // Mission Control takes ⌃↑ and ⌃↓ first while its shortcuts are on (ADR 0161).
            Command(.nextAlbum, "Select Next Album", [.init(.down, ctrl)]),
            Command(.previousAlbum, "Select Previous Album", [.init(.up, ctrl)]),
            Command(
                .extendToNextAlbum, "Extend Selection to Next Album",
                [.init(.down, [ctrl, shift])]),
            Command(
                .extendToPreviousAlbum, "Extend Selection to Previous Album",
                [.init(.up, [ctrl, shift])]),
            Command(.selectFirst, "Select First Row", [.init(.home), .init(.up, [opt, cmd])]),
            Command(.selectLast, "Select Last Row", [.init(.end), .init(.down, [opt, cmd])]),
            Command(.pageDown, "Page Down", [.init(.pageDown)]),
            Command(.pageUp, "Page Up", [.init(.pageUp)]),
            Command(.selectAll, "Select All", [.init("a", cmd)]),

            Command(.find, "Find", [.init("f", cmd)]),
            Command(.sortByTitle, "Sort by Title", [.init("1", [ctrl, opt])]),
            Command(.sortByArtist, "Sort by Artist", [.init("2", [ctrl, opt])]),
            Command(.sortByAlbum, "Sort by Album", [.init("3", [ctrl, opt])]),
            Command(.sortByDateAdded, "Sort by Date Added", [.init("4", [ctrl, opt])]),
            Command(.reverseSort, "Reverse Sort Order", [.init("p", [opt, cmd, shift])]),

            Command(.toggleSidebar, state.sidebarVisible.title, [.init("s", [ctrl, cmd])]),
            Command(.focusSidebar, "Focus Sidebar", [.init("0", cmd)]),
            Command(.toggleStatusBar, state.statusBarVisible.title, [.init("/", cmd)]),
            Command(.toggleToolbar, state.toolbarVisible.title, [.init("t", [opt, cmd])]),
            Command(.distractionFree, "Distraction-Free Mode", [.init("f", [cmd, shift])]),
            Command(.toggleQueue, state.queueVisible.title, [.init("u", [opt, cmd])]),
            Command(.toggleBrowser, state.browserVisible.title, [.init("b", cmd)]),
            Command(
                .toggleSignalPath, state.signalPathVisible.title, [.init("s", [opt, cmd])]),
            Command(.showCurrentTrack, "Show Current Track", [.init("l", cmd)], links: true),
            Command(.showSelectedTrack, "Show Selected Track", [.init("l", [cmd, shift])]),
            Command(.showAllTracks, "Show All Music"),
            Command(.scrollUp, "Scroll Up", [.init(.up, [ctrl, opt])]),
            Command(.scrollDown, "Scroll Down", [.init(.down, [ctrl, opt])]),
            Command(.back, "Back", [.init("[", cmd)], links: true),
            Command(.forward, "Forward", [.init("]", cmd)], links: true),
            Command(.undoSelection, "Undo Selection", [.init("u", cmd)]),
            Command(.redoSelection, "Redo Selection", [.init("u", [cmd, shift])]),
            // The panes take ← and → for these themselves; everywhere else they skip tracks.
            Command(.focusNextPane, "Focus Next Pane"),
            Command(.focusPreviousPane, "Focus Previous Pane"),
            Command(.focusNextArea, "Focus Next Area", [.init(.tab)]),
            Command(.focusPreviousArea, "Focus Previous Area", [.init(.tab, shift)]),

            Command(.addFolder, "Add Watched Folder…", [.init("o", cmd)]),
            Command(.showWatchedFolders, "Watched Folders…"),
            Command(.checkHealth, "Show Library Health"),
            Command(
                .showStats, "Show Listening Stats", argument: statsPeriodArgument, replies: true),
            Command(.showYearInReview, "Show Year in Review"),
            Command(.showDiscogsTagger, "Discogs Tagger…"),
            Command(.showDownloads, "Downloads…"),
            // Not from links: it ignores the playback pause, so a page could keep the NAS busy.
            Command(.rescanNow, "Rescan All"),
            // Not from links either: it reads every file on the NAS.
            Command(.analyzeLibrary, "Analyze Library"),
            Command(.pauseLibraryAnalysis, "Pause Library Analysis"),
            Command(.pauseScan, "Pause Scan"),
            Command(.resumeScan, "Resume Scan"),
            Command(.resolveLostStats, "Resolve Lost Stats…"),
            Command(.restoreRemoved, "Restore Removed Tracks…"),
            Command(.importMoves, "Import Moves…"),
            Command(
                .revealInFinder, "Reveal in Finder",
                [.init("r", cmd), .init("r", [cmd, shift])]),
            Command(.copyPath, "Copy Path", [.init("c", [opt, cmd])]),
            Command(.removeTracks, "Remove…", [.init(.delete)]),
            Command(.editTags, "Get Info", [.init("i", cmd)]),
            Command(.showSpectrum, "Show Spectrum", replies: true, paths: true),
            Command(.undoTagEdit, "Undo Tag Edit", [.init("z", [opt, cmd])]),
            Command(.replaceArtwork, "Replace Artwork…"),
            Command(.removeArtwork, "Remove Artwork"),
            Command(.removeFromQueue, "Remove from Queue or Playlist", [.init(.delete, cmd)]),
            Command(.addToPlaylist, "Add to Playlist…"),
            Command(.showInPlaylist, "Show in Playlist…"),
            Command(.toggleLoved, "Like"),
            Command(.toggleDisliked, "Dislike"),
            Command(.showAlbum, "Show Album"),
            Command(.showArtist, "Show Artist"),
            Command(.showInAllMusic, "Show in All Music", [.init("a", [opt, cmd, shift])]),
            Command(.openDiscogsRelease, "Open Discogs Release", [.init("d", [cmd, shift])]),

            Command(.newPlaylist, "New Playlist", [.init("n", cmd)]),
            Command(
                .newPlaylistFromSelection, "New Playlist with Selected Tracks",
                [.init("n", [cmd, shift])]),
            Command(.newSmartPlaylist, "New Smart Playlist…", [.init("n", [opt, cmd])]),
            Command(.editSmartPlaylist, "Edit Smart Playlist…"),
            Command(.renamePlaylist, "Rename Playlist…"),
            Command(.duplicatePlaylist, "Duplicate Playlist"),
            Command(.deletePlaylist, "Delete Playlist…"),
            Command(.importPlaylist, "Import Playlist…"),
            Command(.exportPlaylist, "Export Playlist…"),
            Command(.importSwinsian, "Import from Swinsian…"),
            Command(.importITunes, "Import iTunes Library…"),

            Command(.playPause, "Play/Pause", [.init(.space)], links: true),
            Command(.play, "Play", links: true, argument: playArgument),
            Command(.pause, "Pause", links: true),
            Command(
                .playSelection, "Play Now", [.init(.return), .init(.down, cmd)],
                links: true),
            Command(.playNext, "Play Next", [.init(.return, opt)], links: true),
            Command(.addToQueue, "Add to Playback Queue"),
            Command(.nextTrack, "Next Track", [.init(.right, cmd), .init(.right)], links: true),
            Command(
                .previousTrack, "Previous Track", [.init(.left, cmd), .init(.left)], links: true),
            // ⌥→ and ⌥← (with or without ⇧) move by word in a field being edited, which takes
            // them first (`KeyChord.isTextEditing`).
            Command(
                .seekForward, "Seek Forward", [.init(.right, [opt, cmd]), .init(.right, opt)],
                links: true),
            Command(
                .seekBack, "Seek Back", [.init(.left, [opt, cmd]), .init(.left, opt)],
                links: true),
            Command(
                .seekForwardPercent,
                "Seek Forward \(seekStepPercent)% or \(seekStepMinimumSeconds) s",
                [.init(.right, [opt, shift])], links: true),
            Command(
                .seekBackPercent, "Seek Back \(seekStepPercent)% or \(seekStepMinimumSeconds) s",
                [.init(.left, [opt, shift])], links: true),
            // Not from links: a page could raise it to full in a loop (ADR 0036).
            Command(.volumeUp, "Volume Up", [.init(.up, [ctrl, cmd])]),
            Command(.volumeDown, "Volume Down", [.init(.down, [ctrl, cmd])], links: true),
            Command(.stop, "Stop", links: true),
            Command(.shuffle, "Shuffle", links: true),
            Command(.repeatOff, "Repeat Off", links: true),
            Command(.repeatAll, "Repeat All", links: true),
            Command(.repeatOne, "Repeat One", links: true),

            // Only Volume Down from links, as for the app's own volume (ADR 0039).
            Command(.receiverVolumeUp, "Receiver Volume Up"),
            Command(.receiverVolumeDown, "Receiver Volume Down", links: true),
            Command(
                .receiverSetVolume, "Set Receiver Volume", argument: receiverVolumeArgument,
                menus: false),
            Command(.receiverMute, "Mute Receiver"),
            Command(.receiverPowerOn, "Turn Receiver On"),
            Command(.receiverStandby, "Put Receiver in Standby"),

            Command(.showSettings, "Settings…", [.init(",", cmd)]),
            Command(.openConfigFile, "Open Config File"),
            Command(.copyDefaultConfig, "Copy Default Config"),
        ]
        + CommandID.rate.enumerated().map { count, id in
            Command(id, count == 0 ? "Clear Rating" : "Rate \(stars(count))")
        }
        + ReceiverSoundMode.allCases.map {
            Command(.receiverSoundMode($0), "Receiver \($0.title)")
        }
        + ReceiverInput.allCases.map {
            Command(.receiverInput($0), "Switch Receiver to \($0.title)")
        }

    /// Every command: those above, then those generated from `settings`.
    public static func all(_ settings: AppSettings = AppSettings()) -> [Command] {
        fixedSet + SettingCommand.all(settings).map(\.command)
    }

    /// The title of `id`, one of the commands written here, for a button or item that runs it.
    public static func title(of id: CommandID) -> String {
        guard let command = fixedSet.first(where: { $0.id == id }) else {
            preconditionFailure("\(id) isn't one of the fixed commands")
        }
        return command.title
    }
}
