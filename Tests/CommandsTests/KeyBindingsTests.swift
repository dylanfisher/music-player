import KeyChord
import Settings
import Testing

@testable import Commands

private let open = CommandID("test.open")
private let close = CommandID("test.close")
private let selectAll = CommandID("test.selectAll")
private let cmd: KeyChord.Modifiers = .command

private let commands = [
    Command(open, "Open", [KeyChord("o", cmd), KeyChord(.down, cmd)]),
    Command(close, "Close", [KeyChord("e", cmd)]),
    Command(selectAll, "Select All", [KeyChord("a", cmd)]),
]
private let rules = ChordRules(
    reserved: [KeyChord("q", cmd): "Quit"], fixed: [selectAll: KeyChord("a", cmd)])

private func bindings(_ overrides: ShortcutOverrides = [:]) throws -> KeyBindings {
    try KeyBindings(commands, overrides: overrides, rules: rules)
}

@Test func twoDefaultsOnOneChordThrow() {
    #expect(throws: CommandConflict.self) {
        try CommandRegistry([
            Command(open, "Open", [KeyChord("o", cmd)]),
            Command(close, "Close", [KeyChord("o", cmd)]),
        ])
    }
    #expect(throws: ReservedDefault.self) {
        try KeyBindings(
            [Command(open, "Open", [KeyChord("q", cmd)])], overrides: [:], rules: rules)
    }
}

@Test func theAppsDefaultsRegister() throws {
    let all = AppCommands.all()
    let bindings = try KeyBindings(all, overrides: [:], rules: AppMenus.rules(appName: "App"))
    #expect(bindings.dropped.isEmpty)
    #expect(bindings.registry.command(for: KeyChord("k", cmd)) == .showPalette)
    #expect(bindings.registry.command(for: KeyChord(.space)) == .playPause)
    #expect(Set(all.map(\.id)).count == all.count)
}

@Test func aPaletteKeysChordsAreApartFromTheAppsAndKeepItsTraits() throws {
    let find = CommandID("test.find")
    let bindings = try KeyBindings(
        commands + [
            Command(find, "Find", [KeyChord("o", cmd)], menus: false, palette: true),
            Command(CommandID("test.args"), "Args", argument: "x", menus: false),
        ], overrides: ["test.find": ShortcutOverride(alternate: .chord(KeyChord("a", cmd)))],
        rules: rules)
    #expect(bindings.registry.command(for: KeyChord("o", cmd)) == open)
    #expect(bindings.registry.command(for: KeyChord("o", cmd), inPalette: true) == find)
    #expect(bindings.registry.command(find)?.inPalette == true)
    #expect(bindings.registry.command(CommandID("test.args"))?.runsFromMenus == false)
    // Select All's fixed chord stays the field's.
    #expect(bindings.registry.command(find)?.chords == [KeyChord("o", cmd)])
    #expect(bindings.dropped.map(\.loss) == [.fixedTo(selectAll)])
}

@Test func aPaletteKeyNeverTypesInTheField() throws {
    let find = CommandID("test.find")
    let space = KeyChord(.space)
    let bindings = try KeyBindings(
        commands + [Command(find, "Find", [KeyChord(.right)], menus: false, palette: true)],
        overrides: ["test.find": ShortcutOverride(alternate: .chord(space))], rules: rules)
    #expect(bindings.registry.command(find)?.chords == [KeyChord(.right)])
    #expect(bindings.dropped.map(\.loss) == [.typesInPalette])
    #expect(bindings.assign(space, to: find, at: .alternate, replacing: true) == .typesInPalette)
    #expect(
        bindings.assign(KeyChord("e", .shift), to: find, at: .primary, replacing: false)
            == .typesInPalette)
    #expect(bindings.problem(id: "test.find", position: .alternate, slot: .chord(space)) != nil)
    // An app command may still have one.
    #expect(
        bindings.assign(space, to: close, at: .alternate, replacing: false)
            == .assigned([close: ShortcutOverride(alternate: .chord(space))]))
}

@Test func commandRRevealsTheSelection() throws {
    let bindings = try KeyBindings(
        AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App"))
    let chord = KeyChord("r", cmd)
    #expect(bindings.registry.command(for: chord) == .revealInFinder)
    #expect(bindings.chord(of: .revealInFinder, at: .primary) == chord)
    // Music's and Swinsian's chord stays as the alternate (ADR 0051).
    #expect(bindings.chord(of: .revealInFinder, at: .alternate) == KeyChord("r", [cmd, .shift]))
}

@Test func eachPaletteHasOneChord() throws {
    let bindings = try KeyBindings(
        AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App"))
    #expect(bindings.registry.command(.showPalette)?.chords == [KeyChord("k", cmd)])
    #expect(bindings.registry.command(.goToItem)?.chords == [KeyChord("p", cmd)])
    #expect(bindings.registry.command(for: KeyChord("p", [cmd, .shift])) == nil)
    #expect(bindings.registry.command(for: KeyChord("k", [cmd, .shift])) == nil)
}

@Test func optionCommandSShowsTheSignalPath() throws {
    let bindings = try KeyBindings(
        AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App"))
    #expect(bindings.dropped.isEmpty)
    #expect(bindings.registry.command(for: KeyChord("s", [.option, cmd])) == .toggleSignalPath)
}

@Test func theUsersChordBeatsADefault() throws {
    let bindings = try bindings([
        close.rawValue: ShortcutOverride(alternate: .chord(KeyChord("o", cmd)))
    ])
    #expect(bindings.registry.command(for: KeyChord("o", cmd)) == close)
    #expect(bindings.chord(of: open, at: .primary) == nil)
    #expect(bindings.chord(of: open, at: .alternate) == KeyChord(.down, cmd))
    #expect(
        bindings.dropped == [
            KeyBindings.Dropped(
                command: open, position: .primary, chord: KeyChord("o", cmd), loss: .takenBy(close))
        ])
}

@Test func storedDataNeverTakesReservedOrFixedChords() throws {
    let bindings = try bindings([
        close.rawValue: ShortcutOverride(primary: .chord(KeyChord("q", cmd))),
        open.rawValue: ShortcutOverride(alternate: .chord(KeyChord("a", cmd))),
        selectAll.rawValue: ShortcutOverride(primary: .removed),
    ])
    #expect(bindings.registry.command(for: KeyChord("q", cmd)) == nil)
    #expect(bindings.registry.command(for: KeyChord("a", cmd)) == selectAll)
    #expect(bindings.chord(of: close, at: .primary) == nil)
    #expect(
        Set(bindings.dropped.map(\.loss)) == [
            .reserved("Quit"), .fixedTo(selectAll), .fixedPrimary,
        ])
}

@Test func assigningFollowsTheRules() throws {
    let bindings = try bindings()
    #expect(
        bindings.assign(KeyChord("q", cmd), to: open, at: .primary, replacing: false)
            == .reserved("Quit"))
    #expect(
        bindings.assign(KeyChord("a", cmd), to: open, at: .alternate, replacing: false)
            == .fixed(to: selectAll))
    #expect(
        bindings.assign(KeyChord("x", cmd), to: selectAll, at: .primary, replacing: false)
            == .fixedPrimary)
    #expect(
        bindings.assign(KeyChord("e", cmd), to: open, at: .primary, replacing: false)
            == .taken(by: close))
    #expect(
        bindings.assign(KeyChord("e", cmd), to: open, at: .primary, replacing: true)
            == .assigned([
                close: ShortcutOverride(primary: .removed),
                open: ShortcutOverride(primary: .chord(KeyChord("e", cmd))),
            ]))
}

@Test func aSlotEqualToItsDefaultIsStoredAsNoChange() throws {
    let changed = try bindings([
        open.rawValue: ShortcutOverride(primary: .chord(KeyChord("y", cmd)))
    ])
    #expect(
        changed.assign(KeyChord("o", cmd), to: open, at: .primary, replacing: false)
            == .assigned([open: ShortcutOverride()]))
    // A chord the command has in its other slot moves.
    #expect(
        try bindings().assign(KeyChord(.down, cmd), to: open, at: .primary, replacing: false)
            == .assigned([
                open: ShortcutOverride(primary: .chord(KeyChord(.down, cmd)), alternate: .removed)
            ]))
    #expect(
        try bindings().remove(from: close, at: .alternate) == .assigned([close: ShortcutOverride()])
    )
    #expect(
        try bindings().remove(from: close, at: .primary)
            == .assigned([close: ShortcutOverride(primary: .removed)]))
    #expect(try bindings().remove(from: selectAll, at: .primary) == .fixedPrimary)
}

@Test func theConfigFileIsCheckedAgainstTheRules() throws {
    let bindings = try bindings()
    #expect(bindings.problem(id: "test.nope", position: .primary, slot: .removed) != nil)
    #expect(
        bindings.problem(id: "test.open", position: .primary, slot: .chord(KeyChord("q", cmd)))
            != nil)
    #expect(
        bindings.problem(id: "test.open", position: .alternate, slot: .chord(KeyChord("a", cmd)))
            != nil)
    #expect(bindings.problem(id: "test.selectAll", position: .primary, slot: .removed) != nil)
    #expect(
        bindings.problem(id: "test.selectAll", position: .primary, slot: .chord(KeyChord("a", cmd)))
            == nil)
    #expect(
        bindings.problem(id: "test.open", position: .primary, slot: .chord(KeyChord("e", cmd)))
            == nil)
}

@Test func booleanAndChoiceSettingsBecomeCommands() {
    let generated = SettingCommand.all(AppSettings())
    let hog = generated.first { $0.key == "output.hogMode" }
    #expect(hog?.action == .toggle)
    #expect(hog?.command.id == CommandID("setting.output.hogMode"))
    #expect(
        generated.filter { $0.key == "appearance" }.map(\.command.title) == [
            "Auto Appearance", "Light Appearance", "Dark Appearance",
        ])
    #expect(
        generated.filter { $0.key.hasPrefix("appearance.") }.map(\.command.title) == [
            "Column Lines", "Row Lines", "Alternating Rows", "Compact Row Height",
            "Regular Row Height", "Large Row Height", "Scaled to Fit Album Art",
            "Full Width Album Art", "Glass", "Minimal Status Bar", "Tall Status Bar",
        ])
    // Numbers, lists and folders aren't commands.
    #expect(!generated.contains { $0.key == "library.watchedFolders" })
}

@Test func everyCommandIsInTheMenus() {
    let listed = AppMenus.commandsByMenu(appName: "App").flatMap(\.commands)
    #expect(Set(listed) == Set(AppCommands.all().filter(\.runsFromMenus).map(\.id)))
    #expect(
        AppCommands.all().filter { !$0.runsFromMenus }.map(\.id) == [
            .filterToItem, .receiverSetVolume,
        ])
    #expect(listed.count == Set(listed).count)
}
