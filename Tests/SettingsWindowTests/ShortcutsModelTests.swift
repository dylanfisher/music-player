import Commands
import KeyChord
import Settings
import Testing

@testable import SettingsWindow

private let cmd: KeyChord.Modifiers = .command
private let optCmd: KeyChord.Modifiers = [.option, .command]

/// The model over the app's commands and menus, saving as the app does: the overrides change and
/// the bindings are made again from them.
@MainActor
private final class Harness {
    var overrides: ShortcutOverrides
    var saves: [[CommandID: ShortcutOverride]] = []
    var model: ShortcutsModel!

    init(_ overrides: ShortcutOverrides = [:]) throws {
        self.overrides = overrides
        model = ShortcutsModel(bindings: try Self.bindings(overrides), appName: "App") {
            [unowned self] changes in
            saves.append(changes)
            for (id, override) in changes {
                self.overrides[id.rawValue] = override.isEmpty ? nil : override
            }
            model.update(try! Self.bindings(self.overrides))
        }
    }

    static func bindings(_ overrides: ShortcutOverrides) throws -> KeyBindings {
        try KeyBindings(
            AppCommands.all(), overrides: overrides, rules: AppMenus.rules(appName: "App"))
    }
}

@MainActor @Test func theSectionsFollowTheMenus() throws {
    let model = try Harness().model!
    #expect(
        model.sections.map(\.title)
            == AppMenus.commandsByMenu(appName: "App").map(\.title))
    let listed = model.sections.flatMap(\.commands)
    #expect(listed.contains(.showPalette))
    #expect(Set(listed).count == listed.count)
}

@MainActor @Test func aClashNamesTheOtherCommandAndCancelKeepsBoth() throws {
    let harness = try Harness()
    let model = harness.model!
    model.record(KeyChord("r", optCmd), for: .find, at: .alternate)
    let notice = try #require(model.notices[.find])
    #expect(
        notice == .taken(chord: KeyChord("r", optCmd), position: .alternate, by: .revealInFinder))
    #expect(model.text(of: notice) == "⌥⌘R is used by Reveal in Finder.")
    #expect(harness.saves.isEmpty)
    model.cancel(for: .find)
    #expect(model.notices[.find] == nil)
    #expect(model.chord(.revealInFinder, .alternate) == KeyChord("r", optCmd))
}

@MainActor @Test func replaceTakesTheChordInOneSave() throws {
    let harness = try Harness()
    let model = harness.model!
    model.record(KeyChord("r", optCmd), for: .find, at: .alternate)
    model.replace(for: .find)
    #expect(harness.saves.count == 1)
    #expect(model.notices[.find] == nil)
    #expect(model.chord(.find, .alternate) == KeyChord("r", optCmd))
    #expect(model.chord(.revealInFinder, .alternate) == nil)
    #expect(model.hasOverride(.find))
    #expect(model.hasOverride(.revealInFinder))
    // A loss made by the user's own Replace isn't a clash in stored data.
    #expect(model.losses(.revealInFinder).isEmpty)
}

@MainActor @Test func reservedAndFixedChordsAreRefused() throws {
    let harness = try Harness()
    let model = harness.model!
    model.record(KeyChord("q", cmd), for: .find, at: .primary)
    #expect(model.notices[.find] == .refused("⌘Q is the Quit App item's, which always takes it."))
    model.record(KeyChord("a", cmd), for: .find, at: .alternate)
    #expect(
        model.notices[.find]
            == .refused("⌘A is Select All's in the Edit menu, for text fields."))
    model.record(KeyChord("j", cmd), for: .selectAll, at: .primary)
    #expect(
        model.notices[.selectAll]
            == .refused("The primary shortcut is the Edit menu's, for text fields."))
    #expect(harness.saves.isEmpty)
}

@MainActor @Test func recordingAFreeChordSavesIt() throws {
    let harness = try Harness()
    let model = harness.model!
    model.record(KeyChord("j", cmd), for: .find, at: .alternate)
    #expect(harness.saves == [[.find: ShortcutOverride(alternate: .chord(KeyChord("j", cmd)))]])
    #expect(model.chord(.find, .alternate) == KeyChord("j", cmd))
    // Recording the default again stores nothing for the command.
    model.record(KeyChord("f", cmd), for: .find, at: .primary)
    model.remove(from: .find, at: .alternate)
    #expect(!model.hasOverride(.find))
}

@MainActor @Test func resetAndResetAllGoBackToTheDefaults() throws {
    let harness = try Harness()
    let model = harness.model!
    model.record(KeyChord("j", cmd), for: .find, at: .primary)
    model.remove(from: .revealInFinder, at: .alternate)
    #expect(model.hasOverrides)
    model.reset(.find)
    #expect(model.chord(.find, .primary) == KeyChord("f", cmd))
    #expect(model.hasOverride(.revealInFinder))
    model.resetAll()
    #expect(!model.hasOverrides)
    #expect(model.chord(.revealInFinder, .alternate) == KeyChord("r", optCmd))
}

@MainActor @Test func aClashInStoredDataIsShownUnderTheLoser() throws {
    let model = try Harness([
        CommandID.find.rawValue: ShortcutOverride(alternate: .chord(KeyChord("k", cmd)))
    ]).model!
    #expect(model.losses(.showPalette) == ["⌘K went to Find."])
}

@MainActor @Test func searchMatchesTitlesAndChords() throws {
    let model = try Harness().model!
    // ⌥⇧⌘P, Reverse Sort Order's, has ⌘P in it too.
    #expect(Set(model.filtered("⌘P").flatMap(\.commands)) == [.goToItem, .reverseSort])
    #expect(model.filtered("go to item").flatMap(\.commands) == [.goToItem])
    #expect(model.filtered("zzz").isEmpty)
    #expect(model.filtered(" ") == model.sections)
}
