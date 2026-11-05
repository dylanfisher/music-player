import Commands
import Settings
import Testing

@testable import Scripting

private let names = CommandNames(AppCommands.all())

private func parse(_ arguments: String...) throws -> ScriptInvocation {
    try parseScriptArguments(arguments, names: names)
}

private func problem(_ arguments: String...) -> String? {
    do {
        _ = try parseScriptArguments(arguments, names: names)
        return nil
    } catch {
        return "\(error)"
    }
}

@Test func aCommandIsNamedByTheLastPartOfItsIDOrTheWholeIDInAnyCase() throws {
    #expect(names.command(named: "next")?.id == .nextTrack)
    #expect(names.command(named: "playback.next")?.id == .nextTrack)
    #expect(names.command(named: "NEXT")?.id == .nextTrack)
    #expect(names.name(of: .nextTrack) == "next")
    #expect(names.command(named: "nope") == nil)
    // Every command is reachable by the name help shows for it.
    for command in AppCommands.all() {
        #expect(names.command(named: names.name(of: command.id))?.id == command.id)
    }
}

@Test func aSharedLastPartOrABuiltinWordNeedsTheWholeID() {
    let all = AppCommands.all()
    var lastParts: [String: Int] = [:]
    for command in all {
        lastParts[
            String(command.id.rawValue.split(separator: ".").last!).lowercased(), default: 0] +=
            1
    }
    for command in all {
        let last = String(command.id.rawValue.split(separator: ".").last!)
        let shared = lastParts[last.lowercased()]! > 1
        #expect(names.name(of: command.id) == (shared ? command.id.rawValue : last))
    }
    #expect(lastParts.keys.contains { $0 == "status" || $0 == "help" } == false)
}

@Test func commandsTheirArgumentsAndOptionsParse() throws {
    #expect(try parse("play").action == .request(.run(.play, argument: nil)))
    #expect(
        try parse("play", "album:Kind of Blue").action
            == .request(.run(.play, argument: "album:Kind of Blue")))
    #expect(try parse("playback.next").action == .request(.run(.nextTrack, argument: nil)))
    #expect(try parse("play", "").action == .request(.run(.play, argument: nil)))
    #expect(try parse("help").action == .help)
    let status = try parse("status", "--json", "--home", "/tmp/h")
    #expect(status == ScriptInvocation(action: .request(.status), json: true, home: "/tmp/h"))
    #expect(try parse("--home", "/tmp/h", "next").launchArguments == ["--home", "/tmp/h"])
    #expect(try parse("next").launchArguments == [])
}

@Test func mistakesFailLoudly() {
    #expect(problem() == "needs a command; `music-player help` lists them")
    #expect(problem("nope") == "nope isn't a command; `music-player help` lists them")
    #expect(problem("next", "--verbose") == "--verbose isn't an option")
    #expect(problem("next", "--home") == "--home needs a folder")
    #expect(problem("next", "--home", "--json") == "--home needs a folder")
    #expect(problem("next", "--home", "a", "--home", "b") == "--home is given twice")
    #expect(problem("next", "--json") == "--json only goes with status and stats")
    #expect(problem("next", "x") == "next takes no argument")
    #expect(problem("play", "a", "b") == "play takes one argument; quote one with spaces")
    #expect(problem("help", "x") == "help takes no argument")
    #expect(problem("status", "x") == "status takes no argument")
    #expect(problem("play", "a\u{1B}[2J") == "the argument holds a control character")
    #expect(
        problem("play", String(repeating: "a", count: 1025)) == "the argument is over 1024 bytes")
}

@Test func helpListsEveryCommandItsArgumentAndWhetherALinkRunsIt() {
    let help = scriptHelp(names)
    let lines = help.split(separator: "\n").map(String.init)
    for command in AppCommands.all() {
        let name = names.name(of: command.id)
        let row = lines.firstIndex { $0.hasPrefix("  \(name) ") || $0 == "  \(name)" }
        guard let row else {
            Issue.record("help has no row for \(name)")
            continue
        }
        // A long usage puts the title on the next line.
        let text =
            lines[row].contains(command.title) || !lines.indices.contains(row + 1)
            ? lines[row] : lines[row] + lines[row + 1]
        #expect(text.contains(command.title), "\(name)")
        #expect(text.contains("(link)") == command.runsFromLinks, "\(name)")
        if let argument = command.argument { #expect(text.contains(argument)) }
    }
    #expect(help.contains("  status [--json]"))
    #expect(help.contains("music-player://play?q=album:Kind%20of%20Blue"))
}

@Test func statsTakesAPeriodAndJSON() throws {
    #expect(try parse("stats").action == .request(.report(.showStats, argument: nil, json: false)))
    #expect(
        try parse("stats", "--period", "2024", "--json").action
            == .request(.report(.showStats, argument: "2024", json: true)))
    #expect(try parse("stats", "week").action == .request(.report(.showStats, argument: "week", json: false)))
    #expect(try parse("stats", "--json").json)
    #expect(problem("stats", "--period") == "--period needs a period: \(StatsPeriod.textHelp)")
    #expect(problem("stats", "--period", "decade") == "--period takes \(StatsPeriod.textHelp), not decade")
    #expect(problem("stats", "--period", "week", "--period", "all") == "--period is given twice")
    #expect(problem("stats", "week", "--period", "all") == "stats takes a period once")
    #expect(problem("next", "--period", "week") == "--period only goes with stats")
    #expect(problem("status", "--period", "week") == "--period only goes with stats")
    #expect(problem("help", "--json") == "help takes no argument")
    #expect(scriptHelp(names).contains("stats [--period <\(StatsPeriod.textHelp)>] [--json]"))
}
