import Commands

/// What a run of the tool asks for, read from its arguments.
public struct ScriptInvocation: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case help
        case request(ScriptRequest)
    }

    public var action: Action
    /// `status --json`.
    public var json = false
    /// `--home`: the app's data folder, as the app's own `--home` takes it.
    public var home: String?

    /// What to start the app with, so it answers where this run looks for it.
    public var launchArguments: [String] { home.map { [ScriptFlag.home.rawValue, $0] } ?? [] }
}

/// A mistake in the tool's arguments, said the way the tool prints it.
struct ScriptUsageError: Error, Equatable, CustomStringConvertible {
    let description: String
}

/// The tool's options. The app's `--home` has the same spelling and meaning.
enum ScriptFlag: String, CaseIterable {
    case home = "--home"
    case json = "--json"
}

/// Reads the tool's arguments, without the executable, against the registry's commands.
public func parseScriptArguments(_ arguments: [String], names: CommandNames)
    throws -> ScriptInvocation
{
    func fail(_ text: String) -> ScriptUsageError { ScriptUsageError(description: text) }
    var words: [String] = []
    var json = false
    var home: String?
    var index = 0
    while index < arguments.count {
        let word = arguments[index]
        index += 1
        guard word.hasPrefix("--") else {
            words.append(word)
            continue
        }
        switch ScriptFlag(rawValue: word) {
        case .home:
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw fail("\(word) needs a folder")
            }
            guard home == nil else { throw fail("\(word) is given twice") }
            home = arguments[index]
            index += 1
        case .json:
            json = true
        case nil:
            throw fail("\(word) isn't an option")
        }
    }
    guard let name = words.first else {
        throw fail("needs a command; `\(toolName) help` lists them")
    }
    let rest = Array(words.dropFirst())
    let action: ScriptInvocation.Action
    if let builtin = CommandNames.Builtin(rawValue: name.lowercased()) {
        guard rest.isEmpty else { throw fail(ScriptMessage.takesNoArgument(builtin.rawValue)) }
        action = builtin == .help ? .help : .request(.status)
    } else {
        guard let command = names.command(named: name) else {
            throw fail(ScriptMessage.notACommand(name) + "; `\(toolName) help` lists them")
        }
        let shown = names.name(of: command.id)
        guard rest.count <= 1 else {
            throw fail("\(shown) takes one argument; quote one with spaces")
        }
        if let argument = rest.first {
            guard command.argument != nil else { throw fail(ScriptMessage.takesNoArgument(shown)) }
            if let problem = ScriptRequest.argumentProblem(argument) { throw fail(problem) }
        }
        // An empty argument is none, as an empty search is no search.
        action = .request(.run(command.id, argument: rest.first.flatMap { $0.isEmpty ? nil : $0 }))
    }
    if json, action != .request(.status) {
        throw fail("\(ScriptFlag.json.rawValue) only goes with \(CommandNames.Builtin.status)")
    }
    return ScriptInvocation(action: action, json: json, home: home)
}

/// `music-player help`: every command the registry has, with its argument and whether a link
/// can run it.
public func scriptHelp(_ names: CommandNames) -> String {
    let builtins: [(String, String)] = [
        (CommandNames.Builtin.help.rawValue, "List the commands"),
        (
            "\(CommandNames.Builtin.status.rawValue) [\(ScriptFlag.json.rawValue)]",
            "What's playing, as text or JSON"
        ),
    ]
    let commands = names.commands.map { command in
        let name = names.name(of: command.id)
        let usage = command.argument.map { "\(name) [<\($0)>]" } ?? name
        return (usage, command.title + (command.runsFromLinks ? "  (link)" : ""))
    }
    let column = 34
    let lines = (builtins + commands).map { usage, title in
        usage.count < column - 2
            ? "  " + usage.padding(toLength: column - 2, withPad: " ", startingAt: 0) + title
            : "  \(usage)\n" + String(repeating: " ", count: column) + title
    }
    let play = names.name(of: .play)
    let intro = [
        "usage: \(toolName) <command> [<argument>] [\(ScriptFlag.home.rawValue) <folder>]",
        "",
        "Runs a command in the app, starting it if it isn't running. \(ScriptFlag.home.rawValue)",
        "reaches an app started with the same \(ScriptFlag.home.rawValue). A command is named by its",
        "ID or the last part of it, in any case.",
        "",
    ]
    let outro = [
        "",
        "Commands marked (link) also run from a link, \(urlScheme)://<command>, with an",
        "argument in ?\(linkArgumentKey)=, as \(urlScheme)://\(play)?\(linkArgumentKey)=album:Kind%20of%20Blue.",
    ]
    return (intro + lines + outro).joined(separator: "\n")
}
