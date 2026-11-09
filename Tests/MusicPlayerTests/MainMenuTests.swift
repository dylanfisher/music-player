import AppKit
import Testing

@testable import Commands
@testable import KeyChord
@testable import Library
@testable import MusicPlayer
@testable import Settings

@MainActor
private func menu(_ overrides: ShortcutOverrides = [:]) throws -> (MainMenu, CommandDispatcher) {
    let dispatcher = CommandDispatcher(
        bindings: try KeyBindings(
            AppCommands.all(), overrides: overrides, rules: AppMenus.rules(appName: "App")))
    return (MainMenu(dispatcher: dispatcher, appName: "App", settings: AppSettings()), dispatcher)
}

/// Every item in `menu` and its submenus, with the submenu's title.
@MainActor
private func items(_ menu: NSMenu) -> [(NSMenuItem, String)] {
    menu.items.flatMap { item in
        [(item, menu.title)] + (item.submenu.map(items) ?? [])
    }
}

/// Every command has a menu item but the settings the Settings window shows instead
/// (ADR 0159), whose hidden items still take their shortcuts.
@MainActor @Test func everyCommandThatRunsFromMenusHasAMenuItem() throws {
    let toggle = SettingCommand.toggleID(AppSettings().separateReleases.key)
    let (menu, _) = try menu([
        toggle.rawValue: ShortcutOverride(primary: .chord(KeyChord("j", [.command, .control])))
    ])
    let offMenus = AppMenus.settingCommandsOffMenus(appName: "App")
    let missing = Set(AppCommands.all().filter(\.runsFromMenus).map(\.id))
        .subtracting(menu.listedCommands).subtracting(offMenus)
    #expect(missing.isEmpty, "no menu item for \(missing.sorted())")
    #expect(offMenus.contains(toggle))
    let item = try #require(
        items(menu.bar).map(\.0).first {
            $0.representedObject as? CommandID == toggle && $0.keyEquivalent == "j"
        })
    #expect(item.isHidden && item.allowsKeyEquivalentWhenHidden)
}

@MainActor @Test func eachItemsKeyEquivalentIsItsCommandsFirstUsableChord() throws {
    let (menu, dispatcher) = try menu()
    for (item, title) in items(menu.bar) {
        guard let id = item.representedObject as? CommandID, !item.isHidden,
            item.action == #selector(MainMenu.runCommand(_:))
        else { continue }
        let first = dispatcher.bindings.registry.command(id)?.chords.first(
            where: \.canBeKeyEquivalent)
        let expected = title == "Selection" ? nil : first
        #expect(item.keyEquivalent == (expected?.keyEquivalent ?? ""), "\(id)")
        #expect(
            item.keyEquivalentModifierMask == (expected?.keyEquivalentModifierMask ?? []), "\(id)")
    }
    // Plain keys stay with the focused view: Space plays, Return plays the selection.
    let play = items(menu.bar).first { ($0.0.representedObject as? CommandID) == .playPause }
    #expect(play?.0.keyEquivalent == "")
}

@MainActor @Test func alternatesGoOnHiddenItemsAndChangeInPlace() throws {
    let (menu, dispatcher) = try menu()
    func reveal() -> [NSMenuItem] {
        items(menu.bar).map(\.0).filter {
            ($0.representedObject as? CommandID) == .revealInFinder
        }
    }
    #expect(reveal().map(\.isHidden) == [false, true])
    #expect(reveal()[1].keyEquivalent == "r")
    #expect(reveal()[1].keyEquivalentModifierMask == [.command, .shift])
    dispatcher.setBindings(
        try KeyBindings(
            AppCommands.all(),
            overrides: [
                CommandID.revealInFinder.rawValue: ShortcutOverride(
                    primary: .chord(KeyChord("j", .command)))
            ],
            rules: AppMenus.rules(appName: "App")))
    menu.showChords()
    #expect(reveal()[0].keyEquivalent == "j")
}

@MainActor @Test func reservedItemsKeepTheirChords() throws {
    let (menu, _) = try menu()
    let quit = items(menu.bar).first { $0.0.action == #selector(NSApplication.terminate(_:)) }
    #expect(quit?.0.keyEquivalent == "q")
    let rules = AppMenus.rules(appName: "App")
    #expect(rules.fixed[.selectAll] == KeyChord("a", .command))
}

/// Settings… and Show Selected Track are commands, so ⌘K and the Shortcuts pane list them too.
@MainActor @Test func settingsAndShowSelectedTrackAreCommandsWithTheirChords() throws {
    let (menu, dispatcher) = try menu()
    func item(_ id: CommandID) -> (NSMenuItem, String)? {
        items(menu.bar).first { ($0.0.representedObject as? CommandID) == id }
    }
    let settings = try #require(item(.showSettings))
    #expect(settings.0.title == "Settings…" && settings.1 == "App")
    #expect(settings.0.keyEquivalent == "," && settings.0.keyEquivalentModifierMask == .command)
    let selected = try #require(item(.showSelectedTrack))
    #expect(selected.1 == "View")
    #expect(selected.0.keyEquivalent == "l")
    #expect(selected.0.keyEquivalentModifierMask == [.command, .shift])
    #expect(
        dispatcher.bindings.registry.command(.showCurrentTrack)?.chords == [KeyChord("l", .command)]
    )
    for id in [CommandID.showSettings, .showSelectedTrack, .openConfigFile] {
        #expect(dispatcher.bindings.registry.command(id)?.runsFromMenus == true, "\(id)")
    }
    var ran: [CommandID] = []
    dispatcher.handle(.showSettings, run: { ran.append(.showSettings) })
    #expect(dispatcher.run(.showSettings))
    #expect(ran == [.showSettings])
}

@MainActor @Test func undoAndRedoSelectionFollowForwardWithTheirChords() throws {
    let (main, dispatcher) = try menu()
    let view = items(main.bar).filter { $0.1 == "View" }.map(\.0)
    let forward = try #require(
        view.firstIndex { ($0.representedObject as? CommandID) == .forward })
    let next = view[(forward + 1)...].filter { !$0.isHidden }.prefix(2)
    #expect(next.map(\.title) == ["Undo Selection", "Redo Selection"])
    #expect(next.map(\.keyEquivalent) == ["u", "u"])
    #expect(next.map(\.keyEquivalentModifierMask) == [.command, [.command, .shift]])
    let registry = dispatcher.bindings.registry
    #expect(registry.command(for: KeyChord("u", .command)) == .undoSelection)
    #expect(registry.command(for: KeyChord("u", [.command, .shift])) == .redoSelection)
    // Rebindable as every command is.
    let (rebound, _) = try menu([
        CommandID.undoSelection.rawValue: ShortcutOverride(primary: .chord(KeyChord("z", .control)))
    ])
    let item = try #require(
        items(rebound.bar).first { ($0.0.representedObject as? CommandID) == .undoSelection })
    #expect(item.0.keyEquivalent == "z" && item.0.keyEquivalentModifierMask == .control)
}

@MainActor @Test func undoTagEditFollowsRedoInTheEditMenuOnOptionCommandZ() throws {
    let (main, dispatcher) = try menu()
    let undo = try #require(
        items(main.bar).first { ($0.0.representedObject as? CommandID) == .undoTagEdit })
    #expect(undo.1 == "Edit")
    #expect(undo.0.keyEquivalent == "z")
    #expect(undo.0.keyEquivalentModifierMask == [.command, .option])
    let edit = items(main.bar).filter { $0.1 == "Edit" }.map(\.0).filter { !$0.isHidden }
    let redo = try #require(edit.firstIndex { $0.title == "Redo" })
    #expect(edit[redo + 1].title == "Undo Tag Edit")
    #expect(
        dispatcher.bindings.registry.command(for: KeyChord("z", [.command, .option]))
            == .undoTagEdit)
    #expect(!items(main.bar).contains { $0.1 == "File" && $0.0.title == "Undo Tag Edit" })
}

@MainActor @Test func focusPreviousAreaFollowsFocusNextAreaOnShiftTab() throws {
    let (main, dispatcher) = try menu()
    let view = items(main.bar).filter { $0.1 == "View" }.map(\.0).filter { !$0.isHidden }
    let next = try #require(
        view.firstIndex { ($0.representedObject as? CommandID) == .focusNextArea })
    #expect(view[next + 1].title == "Focus Previous Area")
    let registry = dispatcher.bindings.registry
    #expect(registry.command(for: KeyChord(.tab)) == .focusNextArea)
    #expect(registry.command(for: KeyChord(.tab, .shift)) == .focusPreviousArea)
}

/// ⌥→ and ⌥← seek 10 s as ⌥⌘→ and ⌥⌘← do; with ⇧, 5% of the track or 30 s, whichever is
/// longer. The Control-arrows seek no more.
@MainActor @Test func theOptionArrowsSeekByTenSecondsOrFivePercentAndAtLeastThirty() throws {
    let (main, dispatcher) = try menu()
    let registry = dispatcher.bindings.registry
    #expect(registry.command(for: KeyChord(.right, .option)) == .seekForward)
    #expect(registry.command(for: KeyChord(.left, .option)) == .seekBack)
    #expect(registry.command(for: KeyChord(.right, [.option, .shift])) == .seekForwardPercent)
    #expect(registry.command(for: KeyChord(.left, [.option, .shift])) == .seekBackPercent)
    for chord in [
        KeyChord(.right, .control), KeyChord(.left, .control),
        KeyChord(.right, [.control, .shift]), KeyChord(.left, [.control, .shift]),
    ] {
        #expect(registry.command(for: chord) == nil, "\(chord)")
    }
    // A field being edited takes them first, to move by word.
    for chord in [
        KeyChord(.right, .option), KeyChord(.left, .option),
        KeyChord(.right, [.option, .shift]), KeyChord(.left, [.option, .shift]),
    ] {
        #expect(chord.isTextEditing, "\(chord)")
    }
    let controls = items(main.bar).filter { $0.1 == "Controls" }.map(\.0)
        .filter { !$0.isHidden }
    let back = try #require(
        controls.firstIndex { ($0.representedObject as? CommandID) == .seekBack })
    #expect(
        controls[(back + 1)...].prefix(2).map(\.title) == [
            "Seek Forward 5% or 30 s", "Seek Back 5% or 30 s",
        ])
    #expect(
        controls[(back + 1)...].prefix(2).map(\.keyEquivalentModifierMask) == [
            [.option, .shift], [.option, .shift],
        ])
    // 5% of 20 minutes is a minute; of 200 s, 10 s, so 30 s; of an unknown length, 30 s.
    #expect(seekSeconds(seekStepShare, ofDuration: 1200) == 60)
    #expect(seekSeconds(-seekStepShare, ofDuration: 1200) == -60)
    #expect(seekSeconds(seekStepShare, ofDuration: 200) == 30)
    #expect(seekSeconds(-seekStepShare, ofDuration: 300) == -30)
    #expect(seekSeconds(seekStepShare, ofDuration: nil) == 30)
    #expect(seekSeconds(-seekStepShare, ofDuration: nil) == -30)
}

@MainActor @Test func theTrackMenuRunsAndValidatesItsCommandsThroughTheDispatcher() throws {
    let (menu, dispatcher) = try menu()
    var ran: [CommandID] = []
    dispatcher.handle(.showAlbum, enabled: { true }, run: { ran.append(.showAlbum) })
    dispatcher.handle(.showArtist, enabled: { false }, run: { ran.append(.showArtist) })
    let shown = items(menu.trackMenu).map(\.0).filter { !$0.isHidden && !$0.isSeparatorItem }
    func item(_ id: CommandID) throws -> NSMenuItem {
        try #require(shown.first { ($0.representedObject as? CommandID) == id })
    }
    #expect(menu.validateMenuItem(try item(.showAlbum)))
    #expect(!menu.validateMenuItem(try item(.showArtist)))
    menu.runCommand(try item(.showAlbum))
    #expect(ran == [.showAlbum])
    #expect(try item(.toggleLoved).title == "Like")
    for title in [AppMenus.addToPlaylistMenuTitle, AppMenus.showInPlaylistMenuTitle] {
        let submenu = try #require(menu.liveMenus[title])
        #expect(menu.trackMenu.items.contains { $0.submenu === submenu })
    }
    // Only the bar's items count toward every command having a menu item.
    #expect(menu.listedCommands.filter { $0 == .showAlbum }.count == 1)
}

@MainActor @Test func aPlaylistSubmenuListsItsPlaylistsOrSaysItHasNone() throws {
    var playlists = [
        Playlist(id: 4, name: "Mix", kind: .manual), Playlist(id: 9, name: "Road", kind: .manual),
    ]
    var chosen: [Int64] = []
    let delegate = PlaylistMenu()
    delegate.playlists = { playlists }
    delegate.choose = { chosen.append($0) }
    let submenu = NSMenu()
    submenu.delegate = delegate
    delegate.menuNeedsUpdate(submenu)
    #expect(submenu.items.map(\.title) == ["Mix", "Road"])
    // AppKit enables items through NSApp, which a test run alone hasn't made yet.
    _ = NSApplication.shared
    submenu.update()
    #expect(submenu.items.map(\.isEnabled) == [true, true])
    submenu.performActionForItem(at: 1)
    #expect(chosen == [9])
    playlists = []
    delegate.menuNeedsUpdate(submenu)
    submenu.update()
    #expect(submenu.items.map(\.title) == ["No Playlists"])
    #expect(submenu.items.map(\.isEnabled) == [false])
}

@MainActor @Test func theOutputMenuListsTheOutputsFoundWithTheOneInUseChecked() throws {
    let (menu, _) = try menu()
    let submenu = try #require(menu.liveMenus[AppMenus.outputMenuTitle])
    let controls = try #require(menu.bar.items.first { $0.title == "Controls" }?.submenu)
    #expect(controls.items.contains { $0.submenu === submenu })
    var options = outputOptions(
        devices: [FoundOutput(id: "Speakers", name: "Speakers")], renderers: [],
        current: .device(uid: "Speakers"))
    var chosen: [OutputChoice] = []
    let output = OutputMenu()
    output.options = { (options, .device(uid: "Speakers")) }
    output.choose = { chosen.append($0) }
    submenu.delegate = output
    output.menuNeedsUpdate(submenu)
    #expect(submenu.items.map(\.title) == ["System Default", "Speakers"])
    #expect(submenu.items.map(\.state) == [.off, .on])
    // AppKit enables items through NSApp, which a test run alone hasn't made yet.
    _ = NSApplication.shared
    submenu.update()
    #expect(submenu.items.map(\.isEnabled) == [true, true])
    submenu.performActionForItem(at: 0)
    #expect(chosen == [.systemDefault])
    // A device plugged in while the menu is open shows at once.
    options.append(OutputOption(choice: .device(uid: "DAC"), title: "DAC"))
    output.menuWillOpen(submenu)
    output.refresh()
    #expect(submenu.items.map(\.title) == ["System Default", "Speakers", "DAC"])
}
