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

/// Any web page can open a link, so this list is the whole of what one can do (ADR 0036).
@Test func onlyPlaybackAndNavigationRunFromLinks() {
    let linked = Set(AppCommands.all().filter(\.runsFromLinks).map(\.id))
    #expect(
        linked == [
            .playPause, .play, .pause, .playSelection, .playNext, .nextTrack, .previousTrack,
            .seekForward, .seekBack, .volumeDown, .stop, .shuffle, .repeatOff,
            .repeatAll, .repeatOne, .back, .forward, .showCurrentTrack,
        ])
    #expect(AppCommands.all().filter { $0.argument != nil }.map(\.id) == [.play])
}
