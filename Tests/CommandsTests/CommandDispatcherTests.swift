import KeyChord
import Testing

@testable import Commands

private let play = CommandID("test.play")
private let stop = CommandID("test.stop")
private let bigger = CommandID("test.bigger")

@MainActor
private func dispatcher() throws -> CommandDispatcher {
    CommandDispatcher(
        bindings: try KeyBindings(
            [
                Command(play, "Play", [KeyChord(.space)]),
                Command(stop, "Stop", [KeyChord(".", .command)]),
                Command(bigger, "Bigger", [KeyChord("+", .command)]),
            ], overrides: [:], rules: ChordRules()))
}

@MainActor @Test func aKeyRunsItsCommandOnlyWhileItsOn() throws {
    let dispatcher = try dispatcher()
    var ran: [CommandID] = []
    var stopping = false
    dispatcher.willRun = { ran.append($0) }
    dispatcher.handle(play) {}
    dispatcher.handle(stop, enabled: { stopping }, run: {})
    #expect(dispatcher.key([KeyChord(.space)]) == .ran)
    #expect(dispatcher.key([KeyChord(".", .command)]) == .refused)
    stopping = true
    #expect(dispatcher.key([KeyChord(".", .command)]) == .ran)
    #expect(dispatcher.key([KeyChord("x", .command)]) == .unbound)
    #expect(ran == [play, stop])
}

@MainActor @Test func aCommandWithNoHandlerIsRefused() throws {
    let dispatcher = try dispatcher()
    #expect(dispatcher.key([KeyChord(.space)]) == .refused)
    #expect(!dispatcher.run(play))
    #expect(!dispatcher.isEnabled(play))
}

/// ⇧⌘= types "+" on a US keyboard; the key's own spelling is tried after what it typed.
@MainActor @Test func aKeyTriesEachSpellingItCanMean() throws {
    let dispatcher = try dispatcher()
    var ran = false
    dispatcher.handle(bigger) { ran = true }
    #expect(dispatcher.key([KeyChord("=", [.command, .shift]), KeyChord("+", .command)]) == .ran)
    #expect(ran)
}

/// A command's title as it would run now, for the menus and the palette; none for one that
/// keeps its registered title.
@MainActor @Test func aHandlerCanNameItsCommandAsItWouldRunNow() throws {
    let dispatcher = try dispatcher()
    var again = false
    dispatcher.handle(play, title: { again ? "Play Again" : "Play" }, run: {})
    dispatcher.handle(stop) {}
    #expect(dispatcher.title(play) == "Play")
    again = true
    #expect(dispatcher.title(play) == "Play Again")
    #expect(dispatcher.title(stop) == nil && dispatcher.title(bigger) == nil)
}
