import Commands
import Foundation
import Playback
import Testing

@testable import Scripting

/// A dispatcher over the real registry whose every command records that it ran.
@MainActor
private final class Recorder {
    let dispatcher: CommandDispatcher
    var ran: [CommandID] = []
    var arguments: [String] = []
    var enabled = true
    /// Seconds, for the link rate.
    var clock = 0.0
    lazy var router = ScriptRouter(
        dispatcher: dispatcher,
        status: { ScriptStatus(PlaybackState(), positionSeconds: nil, track: nil) },
        arguments: [
            .play: { [unowned self] text in
                arguments.append(text)
                if text == "fail" { throw Failure() }
                return "Playing \(text)"
            },
            .receiverSetVolume: { [unowned self] text in
                arguments.append(text)
                return nil
            },
        ],
        reports: [
            .showStats: { [unowned self] text, json in
                arguments.append(text ?? "-")
                if text == "fail" { throw Failure() }
                return json ? "{}" : "stats \(text ?? "shown")"
            }
        ], now: { [unowned self] in clock })

    struct Failure: Error, CustomStringConvertible {
        var description: String { "nothing matches" }
    }

    init() throws {
        dispatcher = CommandDispatcher(
            bindings: try KeyBindings(
                AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "Test")))
        for command in AppCommands.all() {
            dispatcher.handle(
                command.id, enabled: { [unowned self] in enabled },
                run: { [unowned self] in ran.append(command.id) })
        }
    }
}

@MainActor @Test func everyCommandIsRoutedToItsHandlerFromTheCommandLine() async throws {
    let recorder = try Recorder()
    for command in AppCommands.all() {
        let reply = await recorder.router.handle(
            .run(command.id, argument: nil), from: .commandLine)
        #expect(reply == .done(nil), "\(command.id)")
    }
    #expect(recorder.ran == AppCommands.all().map(\.id))
}

@MainActor @Test func aLinkRunsOnlyTheCommandsMarkedForLinks() async throws {
    let recorder = try Recorder()
    for command in AppCommands.all() {
        let reply = await recorder.router.handle(.run(command.id, argument: nil), from: .link)
        #expect(
            reply
                == (command.runsFromLinks
                    ? .done(nil) : .failed("\(command.id) doesn't run from links")))
    }
    #expect(recorder.ran == AppCommands.all().filter(\.runsFromLinks).map(\.id))
    #expect(
        await recorder.router.handle(.status, from: .link)
            == .failed("a link can't ask for the status"))
}

@MainActor @Test func argumentsGoToTheirHandlerAndFailuresAreSaid() async throws {
    let recorder = try Recorder()
    let router = recorder.router
    #expect(await router.handle(.run(.play, argument: "x"), from: .link) == .done("Playing x"))
    #expect(
        await router.handle(.run(.play, argument: "fail"), from: .commandLine)
            == .failed("nothing matches"))
    #expect(
        await router.handle(.run(.nextTrack, argument: "x"), from: .commandLine)
            == .failed("playback.next takes no argument"))
    #expect(
        await router.handle(.run(.play, argument: "a\u{7}"), from: .commandLine)
            == .failed("the argument holds a control character"))
    #expect(
        await router.handle(.run(CommandID("no.such"), argument: nil), from: .commandLine)
            == .failed("no.such isn't a command"))
    recorder.enabled = false
    #expect(
        await router.handle(.run(.nextTrack, argument: nil), from: .commandLine)
            == .failed("Next Track can't run now"))
    #expect(recorder.arguments == ["x", "fail"])
    #expect(recorder.ran.isEmpty)
}

@MainActor @Test func theSocketRunsARequestAndRefusesOneThatDoesntDecode() async throws {
    let recorder = try Recorder()
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sr-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: home) }
    let path = scriptSocketPath(dataDirectory: home)
    let server = try startScriptServer(path: path, router: recorder.router, problem: { _ in })
    defer { server.stop() }
    // Off the main actor, which the router needs while the exchange waits.
    let next = try await Task.detached {
        try sendScriptRequest(.run(.nextTrack, argument: nil), path: path)
    }.value
    #expect(next == .done(nil))
    let status = try await Task.detached { try sendScriptRequest(.status, path: path) }.value
    #expect(status == .status(ScriptStatus(PlaybackState(), positionSeconds: nil, track: nil)))
    let garbage = try await Task.detached {
        try JSONDecoder().decode(
            ScriptReply.self,
            from: try localSocketExchangeForTests(
                path: path, Data(#"{"kind":"run","command":"playback.next","extra":1}"#.utf8)))
    }.value
    guard case .failed(let reason) = garbage else {
        Issue.record("an extra key was accepted: \(garbage)")
        return
    }
    #expect(reason.hasPrefix("the request didn't decode"))
    #expect(recorder.ran == [.nextTrack])
}

@MainActor @Test func linksPastFiveASecondAreRefusedWhateverTheyAsk() async throws {
    let recorder = try Recorder()
    let router = recorder.router
    for _ in 0..<4 { #expect(await router.link("music-player://next") == .done(nil)) }
    // A refused link counts too: a page spends its share whatever it asks for.
    guard case .failed = await router.link("music-player://library.addFolder") else {
        Issue.record("a command not marked for links ran")
        return
    }
    let over = "over 5 links in a second came, and this one was refused"
    #expect(await router.link("music-player://pause") == .failed(over))
    recorder.clock = 0.99
    #expect(await router.link("music-player://pause") == .failed(over))
    recorder.clock = 1.0
    #expect(await router.link("music-player://pause") == .done(nil))
    #expect(recorder.ran == Array(repeating: .nextTrack, count: 4) + [.pause])
}

@MainActor @Test func aReplyingCommandAnswersTheCommandLineWithWhatItFound() async throws {
    let recorder = try Recorder()
    let router = recorder.router
    #expect(
        await router.handle(.report(.showStats, argument: nil, json: false), from: .commandLine)
            == .done("stats shown"))
    #expect(
        await router.handle(.report(.showStats, argument: "2024", json: true), from: .commandLine)
            == .done("{}"))
    #expect(
        await router.handle(.report(.showStats, argument: "fail", json: false), from: .commandLine)
            == .failed("nothing matches"))
    #expect(
        await router.handle(.report(.showStats, argument: nil, json: false), from: .link)
            == .failed("a link can't ask for library.stats"))
    #expect(
        await router.handle(.report(.nextTrack, argument: nil, json: true), from: .commandLine)
            == .failed("playback.next doesn't reply; run it without --json"))
    #expect(recorder.arguments == ["-", "2024", "fail"])
    // Run as a plain command, as the menu runs it, it shows Stats and says nothing.
    #expect(await router.handle(.run(.showStats, argument: nil), from: .commandLine) == .done(nil))
    #expect(recorder.ran == [.showStats])
}

@Test func aReportRequestRoundTrips() throws {
    let request = ScriptRequest.report(.showStats, argument: "week", json: true)
    let data = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(ScriptRequest.self, from: data) == request)
    let plain = ScriptRequest.report(.showStats, argument: nil, json: false)
    #expect(
        try JSONDecoder().decode(ScriptRequest.self, from: try JSONEncoder().encode(plain)) == plain
    )
}
