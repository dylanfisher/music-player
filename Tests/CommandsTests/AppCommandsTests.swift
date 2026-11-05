import KeyChord
import Receiver
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
            "-", "Like", "Dislike", "-", "Rating ▸ 6", "-", "Get Info", "Reveal in Finder", "-",
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
    #expect(AppCommands.all().filter(\.replies).map(\.id) == [.showStats])
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
