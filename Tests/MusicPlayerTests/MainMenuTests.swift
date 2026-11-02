import AppKit
import Testing

@testable import Commands
@testable import KeyChord
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
    #expect(reveal()[1].keyEquivalentModifierMask == [.command, .option])
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
    #expect(rules.reserved[KeyChord(",", .command)] == "Settings…")
    #expect(rules.fixed[.selectAll] == KeyChord("a", .command))
}

@MainActor @Test func settingsReachesTheAppDelegate() {
    #expect(
        AppDelegate.instancesRespond(to: NSSelectorFromString(AppMenus.showSettingsAction)))
}
