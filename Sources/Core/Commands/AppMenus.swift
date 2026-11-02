import KeyChord
import Receiver
import Settings

/// A standard AppKit item: its action goes up the responder chain by selector name, and its
/// chord can't be given to a command. An item that `runs` a command (Select All) has that
/// command's fixed primary as its chord.
public struct StandardItem: Sendable {
    public var title: String
    /// An Objective-C selector name, such as "terminate:".
    public var action: String
    public var chord: KeyChord?
    public var runs: CommandID?

    init(_ title: String, _ action: String, _ chord: KeyChord? = nil, runs: CommandID? = nil) {
        self.title = title
        self.action = action
        self.chord = chord
        self.runs = runs
    }
}

public indirect enum MenuEntry: Sendable {
    case command(CommandID)
    case standard(StandardItem)
    /// `showsChords` false keeps every item keyless, as the row movement keys are: text fields
    /// move by them too, and each repeat of a held key would otherwise search the menu bar.
    case submenu(String, [MenuEntry], showsChords: Bool)
    /// The commands made from the setting with this key: one item, or a submenu of choices.
    case setting(String)
    case separator
}

public struct MenuSection: Sendable {
    public enum Role: Sendable {
        case app, plain, window, help
    }

    public var title: String
    public var role: Role
    public var entries: [MenuEntry]
}

/// The main menu bar as data, so the App tier builds it, the Shortcuts pane lists commands in
/// its order, and the chord rules come from its standard items.
public enum AppMenus {
    /// The action the Settings… item sends, which the app's delegate answers.
    static let showSettingsAction = "showSettings:"

    public static func sections(appName: String) -> [MenuSection] {
        let cmd: KeyChord.Modifiers = .command
        let settings = AppSettings()
        return [
            MenuSection(
                title: appName, role: .app,
                entries: [
                    .standard(StandardItem("About \(appName)", "orderFrontStandardAboutPanel:")),
                    .separator,
                    .standard(StandardItem("Settings…", showSettingsAction, KeyChord(",", cmd))),
                    .command(.openConfigFile), .command(.copyDefaultConfig), .separator,
                    .standard(StandardItem("Hide \(appName)", "hide:", KeyChord("h", cmd))),
                    .standard(
                        StandardItem(
                            "Hide Others", "hideOtherApplications:", KeyChord("h", [.option, cmd]))),
                    .standard(StandardItem("Show All", "unhideAllApplications:")), .separator,
                    .standard(StandardItem("Quit \(appName)", "terminate:", KeyChord("q", cmd))),
                ]),
            MenuSection(
                title: "File", role: .plain,
                entries: [
                    .command(.newPlaylist), .command(.newPlaylistFromSelection),
                    .command(.newSmartPlaylist), .command(.editSmartPlaylist),
                    .command(.renamePlaylist), .command(.deletePlaylist), .separator,
                    .command(.importPlaylist), .command(.exportPlaylist),
                    .command(.importSwinsian), .command(.importITunes), .separator,
                    .command(.addFolder), .command(.showWatchedFolders), .command(.checkHealth),
                    .command(.rescanNow),
                    .command(.resolveLostStats),
                    .setting(settings.pausePollingDuringPlayback.key),
                    .setting(settings.rescanNetworkFoldersAtLaunch.key),
                    .setting(settings.groupByAlbumArtist.key),
                    .separator, .command(.revealInFinder), .command(.copyPath),
                    .command(.addToPlaylist), .separator, .command(.editTags),
                    .command(.undoTagEdit), .command(.replaceArtwork), .command(.removeArtwork),
                    .submenu("Rating", CommandID.rate.map(MenuEntry.command), showsChords: true),
                    .command(.toggleLoved), .separator,
                    .standard(StandardItem("Close Window", "performClose:", KeyChord("w", cmd))),
                ]),
            MenuSection(
                title: "Edit", role: .plain,
                entries: [
                    .standard(StandardItem("Undo", "undo:", KeyChord("z", cmd))),
                    .standard(StandardItem("Redo", "redo:", KeyChord("z", [cmd, .shift]))),
                    .separator,
                    .standard(StandardItem("Cut", "cut:", KeyChord("x", cmd))),
                    .standard(StandardItem("Copy", "copy:", KeyChord("c", cmd))),
                    .standard(StandardItem("Paste", "paste:", KeyChord("v", cmd))),
                    .standard(
                        StandardItem(
                            AppCommands.title(of: .selectAll), "selectAll:", KeyChord("a", cmd),
                            runs: .selectAll)
                    ),
                    .submenu(
                        "Selection",
                        [
                            .command(.selectNext), .command(.selectPrevious),
                            .command(.extendDown), .command(.extendUp), .command(.tenRowsDown),
                            .command(.tenRowsUp), .command(.selectFirst), .command(.selectLast),
                            .command(.pageDown), .command(.pageUp),
                        ], showsChords: false),
                    .separator, .command(.find), .separator, .command(.removeFromQueue),
                ]),
            MenuSection(
                title: "View", role: .plain,
                entries: [
                    .command(.showPalette), .command(.goToItem), .separator,
                    .command(.toggleSidebar), .command(.toggleBrowser), .command(.toggleStatusBar),
                    .command(.toggleQueue), .command(.toggleSignalPath),
                    .separator, .command(.focusSidebar), .command(.focusNextPane),
                    .command(.focusPreviousPane), .command(.focusNextArea), .separator,
                    .submenu(
                        "Sort By",
                        [
                            .command(.sortByTitle), .command(.sortByArtist),
                            .command(.sortByAlbum), .command(.sortByDateAdded), .separator,
                            .command(.reverseSort),
                        ], showsChords: true),
                    .separator, .command(.back), .command(.forward), .command(.showCurrentTrack),
                    .command(.showAllTracks), .separator, .setting(settings.appearance.key),
                ]),
            MenuSection(
                title: "Controls", role: .plain,
                entries: [
                    .command(.playPause), .command(.play), .command(.pause),
                    .command(.playSelection), .command(.playNext),
                    .command(.stop), .separator, .command(.nextTrack), .command(.previousTrack),
                    .command(.seekForward), .command(.seekBack), .separator, .command(.shuffle),
                    .submenu(
                        "Repeat",
                        [.command(.repeatOff), .command(.repeatAll), .command(.repeatOne)],
                        showsChords: true),
                    .separator, .command(.volumeUp), .command(.volumeDown), .separator,
                    .setting(settings.hogMode.key), .setting(settings.digitalVolume.key),
                    .separator,
                    .submenu(
                        "Receiver",
                        [
                            .setting(settings.receiverEnabled.key),
                            .setting(settings.receiverVolumeKeys.key), .separator,
                            .command(.receiverVolumeUp), .command(.receiverVolumeDown),
                            .command(.receiverMute), .separator,
                        ] + ReceiverSoundMode.allCases.map { .command(.receiverSoundMode($0)) }
                            + [
                                .separator,
                                .submenu(
                                    "Input",
                                    ReceiverInput.allCases.map { .command(.receiverInput($0)) },
                                    showsChords: true),
                                .separator, .command(.receiverPowerOn), .command(.receiverStandby),
                            ], showsChords: true),
                ]),
            MenuSection(
                title: "Window", role: .window,
                entries: [
                    .standard(StandardItem("Minimize", "performMiniaturize:", KeyChord("m", cmd))),
                    .standard(StandardItem("Zoom", "performZoom:")), .separator,
                    .standard(StandardItem("Bring All to Front", "arrangeInFront:")),
                ]),
            // AppKit puts its menu search field in the help menu.
            MenuSection(title: "Help", role: .help, entries: []),
        ]
    }

    /// The reserved and fixed chords, from the standard items.
    public static func rules(appName: String) -> ChordRules {
        var rules = ChordRules()
        func visit(_ entries: [MenuEntry]) {
            for entry in entries {
                switch entry {
                case .standard(let item):
                    guard let chord = item.chord else { continue }
                    if let command = item.runs {
                        rules.fixed[command] = chord
                    } else {
                        rules.reserved[chord] = item.title
                    }
                case .submenu(_, let entries, _): visit(entries)
                case .command, .setting, .separator: continue
                }
            }
        }
        for section in sections(appName: appName) { visit(section.entries) }
        return rules
    }

    /// Each menu's commands in menu order, submenus included, with the commands a standard item
    /// runs: the order the Shortcuts pane lists them in.
    public static func commandsByMenu(appName: String, settings: AppSettings = AppSettings())
        -> [(title: String, commands: [CommandID])]
    {
        let generated = SettingCommand.all(settings)
        func ids(_ entries: [MenuEntry]) -> [CommandID] {
            entries.flatMap { entry -> [CommandID] in
                switch entry {
                case .command(let id): [id]
                case .standard(let item): item.runs.map { [$0] } ?? []
                case .submenu(_, let entries, _): ids(entries)
                case .setting(let key): generated.filter { $0.key == key }.map(\.command.id)
                case .separator: []
                }
            }
        }
        return sections(appName: appName).map { ($0.title, ids($0.entries)) }
            .filter { !$0.commands.isEmpty }
    }
}
