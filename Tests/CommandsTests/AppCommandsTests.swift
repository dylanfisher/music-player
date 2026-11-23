import KeyChord
import Receiver
import Settings
import Testing

@testable import Commands

@Test func everyFixedCommandsTitleIsFoundByItsID() {
    for command in AppCommands.fixedSet {
        #expect(AppCommands.title(of: command.id) == command.title)
    }
}

@Test func theEditMenusSelectAllHasItsCommandsTitle() throws {
    let items = AppMenus.sections(appName: "Test").flatMap(\.entries).compactMap { entry in
        if case .standard(let item) = entry, item.runs == .selectAll { item } else { nil }
    }
    #expect(items.map(\.title) == [AppCommands.title(of: .selectAll)])
}

@Test func theTrackMenuIsGroupedAsSwinsiansWithEveryItemACommand() {
    func titles(_ entries: [MenuEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .command(let id): AppCommands.title(of: id)
            case .submenu(let title, let entries, _): "\(title) ▸ \(titles(entries).count)"
            case .live(let title): "\(title) ▸"
            case .separator: "-"
            case .standard, .setting: "not a track command"
            }
        }
    }
    #expect(
        titles(AppMenus.trackMenu) == [
            "Play Next", "Add to Playback Queue", "Play Now", "-", "Show Album", "Show Artist",
            "Show in All Music", "Open Discogs Release", "Get Discogs Artwork…",
            "Combine Albums for Tagging…", "Never Upgrade", "-", "Recommendations for Album",
            "Recommendations for Artist", "Show Discography ▸", "Show Threads", "Not Now", "-",
            "Like",
            "Dislike", "-", "Rating ▸ 6",
            "-", "Get Info", "Show Spectrum",
            "Reveal in Finder", "Rescan Selected Files", "-",
            "Remove…", "-", "New Playlist with Selected Tracks", "Add to Playlist ▸",
            "Show in Playlist ▸",
        ])
}

/// A paired remote runs playback, the queue, the volumes, the output and the receiver, and
/// nothing that writes tags, moves files, changes another setting or approves a download
/// (ADR 0214).
@Test func onlyPlaybackVolumeOutputAndTheReceiverRunFromTheRemote() {
    let remote = Set(AppCommands.all().filter(\.runsFromRemote).map(\.id))
    let receiver: Set<CommandID> = [
        .receiverVolumeUp, .receiverVolumeDown, .receiverSetVolume, .receiverMute,
        .receiverPowerOn, .receiverStandby,
    ]
    let playback: Set<CommandID> = [
        .playPause, .play, .pause, .nextTrack, .previousTrack, .seekForward, .seekBack,
        .seekForwardPercent, .seekBackPercent, .seekTo, .volumeUp, .volumeDown,
        .setAppVolume, .chooseOutput, .stop, .shuffle, .repeatOff, .repeatAll, .repeatOne,
        .playTracks, .playList, .queueTracks, .moveInQueue, .removeFromQueueAt,
    ]
    #expect(
        remote
            == playback.union(receiver).union(ReceiverInput.allCases.map(CommandID.receiverInput)))
    #expect(!remote.contains { $0.rawValue.hasPrefix("setting.") })
}

@Test func seekToAndSetVolumeTakeAPlainNumberInRange() {
    #expect(CommandArgument.seconds("12.5") == 12.5)
    #expect(CommandArgument.seconds("0") == 0)
    for text in ["-1", "1e3", "", ".5", "5.", "1.2.3", "nan", "inf", "86401", "0x10", " 1"] {
        #expect(CommandArgument.seconds(text) == nil, "\(text)")
    }
    #expect(CommandArgument.decibels("-12", in: -60...0) == -12)
    #expect(CommandArgument.decibels("+1", in: -60...0) == nil)
    #expect(CommandArgument.decibels("--1", in: -60...0) == nil)
    #expect(CommandArgument.decibels("-61", in: -60...0) == nil)
}

@Test func playTracksTakesIDsOrAnAlbumAndTheQueueEditsAStampAndPositions() {
    #expect(CommandArgument.tracks("tracks:3,1,2", startAllowed: false) == .tracks([3, 1, 2]))
    #expect(CommandArgument.tracks("album:7", startAllowed: false) == .album(7, start: nil))
    #expect(CommandArgument.tracks("album:7:9", startAllowed: true) == .album(7, start: 9))
    let tooMany = (1...(CommandArgument.maximumTracks + 1)).map(String.init).joined(separator: ",")
    for text in [
        "album:7:9", "tracks:", "tracks:1,", "tracks:0", "tracks:-1", "tracks: 1", "album:",
        "album:7:", "album:7:9:1", "albums:7", "7", "tracks:" + tooMany,
        "tracks:1234567890123456789",
    ] {
        #expect(CommandArgument.tracks(text, startAllowed: false) == nil, "\(text)")
    }
    #expect(CommandArgument.queuePlaces("4:0:2", count: 2)?.places == [0, 2])
    #expect(CommandArgument.queuePlaces("4:0", count: 1)?.stamp == 4)
    for text in ["4:0", "4:0:1:2", "4::1", ":0:1", "4:+1:2", "4:a:1"] {
        #expect(CommandArgument.queuePlaces(text, count: 2) == nil, "\(text)")
    }
}

/// Any web page can open a link, so this list is the whole of what one can do (ADR 0036).
@Test func onlyPlaybackAndNavigationRunFromLinks() {
    let linked = Set(AppCommands.all().filter(\.runsFromLinks).map(\.id))
    #expect(
        linked == [
            .playPause, .play, .pause, .playSelection, .playNext, .nextTrack, .previousTrack,
            .seekForward, .seekBack, .seekForwardPercent, .seekBackPercent, .volumeDown,
            .stop, .shuffle, .repeatOff,
            .repeatAll, .repeatOne, .back, .forward, .showCurrentTrack, .receiverVolumeDown,
        ])
    #expect(
        AppCommands.all().filter { $0.argument != nil }.map(\.id)
            == [
                .showStats, .play, .seekTo, .setAppVolume, .chooseOutput, .playTracks,
                .playList, .queueTracks, .moveInQueue, .removeFromQueueAt, .receiverSetVolume,
            ])
    #expect(AppCommands.all().filter(\.replies).map(\.id) == [.showStats, .showSpectrum])
    #expect(AppCommands.all().filter(\.takesPaths).map(\.id) == [.showSpectrum])
}

/// Analyze Library runs from the File menu, so the palette and the command line, its pause
/// beside it (ADR 0116), and Pause Scan and Resume Scan after them (ADR 0119).
@Test func analyzeLibraryAndItsPauseFollowLibraryHealthInTheFileMenu() throws {
    let file = try #require(AppMenus.sections(appName: "Test").first { $0.title == "File" })
    let ids = file.entries.compactMap { entry in
        if case .command(let id) = entry { id } else { nil }
    }
    let health = try #require(ids.firstIndex(of: .checkHealth))
    #expect(
        Array(ids[health...].prefix(5)) == [
            .checkHealth, .analyzeLibrary, .pauseLibraryAnalysis, .pauseScan, .resumeScan,
        ])
    #expect(AppCommands.title(of: .analyzeLibrary) == "Analyze Library")
    #expect(AppCommands.title(of: .pauseLibraryAnalysis) == "Pause Library Analysis")
    #expect(AppCommands.title(of: .pauseScan) == "Pause Scan")
    #expect(AppCommands.title(of: .resumeScan) == "Resume Scan")
}

/// The File menu lists no setting: those it had are in the Settings window or the tagger, and
/// their commands are the Shortcuts pane's and the palette's Settings section (ADR 0159). Its
/// rarely used commands are in two submenus.
@Test func theFileMenuHasNoSettingsAndItsRareCommandsInSubmenus() throws {
    let file = try #require(AppMenus.sections(appName: "Test").first { $0.title == "File" })
    func settings(_ entries: [MenuEntry]) -> [String] {
        entries.flatMap { entry -> [String] in
            switch entry {
            case .setting(let key): [key]
            case .submenu(_, let entries, _): settings(entries)
            default: []
            }
        }
    }
    #expect(settings(file.entries).isEmpty)
    let submenus = Dictionary(
        uniqueKeysWithValues: file.entries.compactMap { entry -> (String, [CommandID])? in
            guard case .submenu(let title, let entries, _) = entry, title != "Rating" else {
                return nil
            }
            return (
                title,
                entries.compactMap { if case .command(let id) = $0 { id } else { nil } }
            )
        })
    #expect(
        submenus == [
            "Import from Other Players": [.importSwinsian, .importITunes],
            "Moved and Removed Files": [
                .resolveLostStats, .restoreRemoved, .importMoves, .organizeFiles,
            ],
        ])

    let schema = AppSettings()
    let sections = AppMenus.commandsByMenu(appName: "Test")
    #expect(sections.last?.title == AppMenus.settingsSectionTitle)
    let unlisted = Set(sections.last?.commands ?? [])
    #expect(unlisted.contains(SettingCommand.toggleID(schema.separateReleases.key)))
    #expect(unlisted.contains(SettingCommand.toggleID(schema.groupByAlbumArtist.key)))
    #expect(!unlisted.contains(SettingCommand.toggleID(schema.hogMode.key)))
}

@Test func everyReceiverInputAndSoundModeIsACommand() {
    let ids = Set(AppCommands.all().map(\.id))
    #expect(ids.contains(CommandID("receiver.inputCableSatellite")))
    #expect(ids.contains(CommandID("receiver.modePureDirect")))
    #expect(ReceiverInput.allCases.allSatisfy { ids.contains(.receiverInput($0)) })
    #expect(ReceiverSoundMode.allCases.allSatisfy { ids.contains(.receiverSoundMode($0)) })
    #expect(AppCommands.title(of: .receiverInput(.bluRay)) == "Switch Receiver to Blu-ray")
}

/// ← and → skip tracks from a list; the panes take them before the registry to move between
/// panes, so Focus Next and Previous Pane have no chord of their own.
@Test func leftAndRightSkipTracks() throws {
    let registry = try CommandRegistry(AppCommands.all())
    #expect(registry.command(for: KeyChord(.right)) == .nextTrack)
    #expect(registry.command(for: KeyChord(.left)) == .previousTrack)
    #expect(registry.command(.focusNextPane)?.chords == [])
    #expect(registry.command(.focusPreviousPane)?.chords == [])
}

/// Focus Mode is gone (ADR 0216): its ⌥⌘F is unbound and no command is named for it. The
/// `focus.*` commands, which move the keys, stay.
@Test func noCommandIsLeftOfFocusMode() throws {
    let registry = try CommandRegistry(AppCommands.all())
    #expect(registry.command(for: KeyChord("f", [.option, .command])) == nil)
    let named = AppCommands.all().filter {
        $0.id.rawValue.lowercased().contains("focusmode")
            || $0.title.lowercased().contains("focus mode")
    }
    #expect(named.isEmpty, "\(named.map(\.id))")
    #expect(registry.command(.focusSidebar) != nil)
}

/// ⌘⌥⇧0 clears the rating and ⌘⌥⇧1 to ⌘⌥⇧5 rate, taking no other command's chord.
@Test func theRatingCommandsHaveTheDigitsWithCommandOptionAndShift() throws {
    let bindings = try KeyBindings(
        AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "Test"))
    #expect(bindings.dropped.isEmpty)
    for (stars, id) in CommandID.rate.enumerated() {
        let chord = KeyChord(.character(Character(String(stars))), [.command, .option, .shift])
        #expect(bindings.registry.command(id)?.chords == [chord])
        #expect(bindings.registry.command(for: chord) == id)
    }
}

@Test func theEditMenuHasCopyPasteAndDeleteAsStandardItems() throws {
    let edit = try #require(AppMenus.sections(appName: "Test").first { $0.title == "Edit" })
    let standard = edit.entries.compactMap { entry in
        if case .standard(let item) = entry { item.action } else { nil }
    }
    #expect(Array(standard.drop { $0 != "copy:" }.prefix(3)) == ["copy:", "paste:", "delete:"])
    let delete = edit.entries.compactMap { entry in
        if case .standard(let item) = entry, item.action == "delete:" { item } else { nil }
    }
    // ⌫ stays Remove…'s.
    #expect(delete.first?.chord == nil)
}

@Test func threadsFiltersReadAsCommandsInThePalette() {
    let schema = AppSettings()
    let keys: Set<String> = [
        schema.threadsOtherArtistsOnly.key, schema.threadsHiddenKinds.key,
        schema.threadsPlayed.key, schema.threadsYears.key,
    ]
    let titles = SettingCommand.all(schema).filter { keys.contains($0.key) }.map(\.command.title)
    #expect(
        titles == [
            "Other Artists Only in Threads", "Any Time Thread Albums",
            "Never Played Thread Albums", "Not in a Year Thread Albums",
            "Any Year of the Seed in Threads", "Within 5 Years of the Seed in Threads",
            "Within 10 Years of the Seed in Threads",
        ])
}
