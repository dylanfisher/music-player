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
            "Show in All Music", "Open Discogs Release", "-", "Like", "Dislike", "-", "Rating ▸ 6",
            "-", "Get Info", "Show Spectrum",
            "Reveal in Finder", "-",
            "Remove…", "-", "New Playlist with Selected Tracks", "Add to Playlist ▸",
            "Show in Playlist ▸",
        ])
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
            == [.showStats, .play, .receiverSetVolume])
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
            "Moved and Removed Files": [.resolveLostStats, .restoreRemoved, .importMoves],
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
