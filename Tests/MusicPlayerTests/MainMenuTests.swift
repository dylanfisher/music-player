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

@MainActor @Test func everyCommandThatRunsFromMenusHasAMenuItem() throws {
    let (menu, _) = try menu()
    let missing = Set(AppCommands.all().filter(\.runsFromMenus).map(\.id))
        .subtracting(menu.listedCommands)
    #expect(missing.isEmpty, "no menu item for \(missing.sorted())")
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
