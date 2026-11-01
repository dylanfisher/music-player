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
    lazy var router = ScriptRouter(
        dispatcher: dispatcher,
        status: { ScriptStatus(PlaybackState(), positionSeconds: nil, track: nil) },
        arguments: [
            .play: { [unowned self] text in
                arguments.append(text)
                if text == "fail" { throw Failure() }
                return "Playing \(text)"
            }
        ])

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
