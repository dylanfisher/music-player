import Commands
import Foundation
import Settings

/// What a run of the tool asks for, read from its arguments.
public struct ScriptInvocation: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case help
        case request(ScriptRequest)
    }

    public var action: Action
    /// `status --json`, or a replying command's.
    public var json = false
    /// `--home`: the app's data folder, as the app's own `--home` takes it.
    public var home: String?
    /// How long the tool waits for the reply: longer for a command that reads files.
    public var replySeconds = ScriptLimits.replySeconds

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
    /// Show Listening Stats' period, as its argument.
    case period = "--period"
}

/// Reads the tool's arguments, without the executable, against the registry's commands. A
/// command's relative paths are taken from `currentDirectory`.
public func parseScriptArguments(
    _ arguments: [String], names: CommandNames,
    currentDirectory: String = FileManager.default.currentDirectoryPath
) throws -> ScriptInvocation {
    func fail(_ text: String) -> ScriptUsageError { ScriptUsageError(description: text) }
    var words: [String] = []
    var json = false
    var home: String?
    var period: String?
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
        case .period:
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw fail("\(word) needs a period: \(StatsPeriod.textHelp)")
            }
            guard period == nil else { throw fail("\(word) is given twice") }
            guard StatsPeriod(text: arguments[index]) != nil else {
                throw fail("\(word) takes \(StatsPeriod.textHelp), not \(arguments[index])")
            }
            period = arguments[index]
            index += 1
        case nil:
            throw fail("\(word) isn't an option")
        }
    }
    guard let name = words.first else {
        throw fail("needs a command; `\(toolName) help` lists them")
    }
    let rest = Array(words.dropFirst())
    let action: ScriptInvocation.Action
    var replySeconds = ScriptLimits.replySeconds
    var paths: [String] = []
    if let builtin = CommandNames.Builtin(rawValue: name.lowercased()) {
        guard rest.isEmpty else { throw fail(ScriptMessage.takesNoArgument(builtin.rawValue)) }
        action = builtin == .help ? .help : .request(.status)
    } else {
        guard let command = names.command(named: name) else {
            throw fail(ScriptMessage.notACommand(name) + "; `\(toolName) help` lists them")
        }
        let shown = names.name(of: command.id)
        guard rest.count <= 1 || command.takesPaths else {
            throw fail("\(shown) takes one argument; quote one with spaces")
        }
        if command.takesPaths {
            paths = rest.map { word in
                URL(
                    fileURLWithPath: word, isDirectory: false,
                    relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)
                ).standardizedFileURL.path
            }
            if let problem = paths.lazy.compactMap(ScriptRequest.pathProblem).first {
                throw fail(problem)
            }
            let request = ScriptRequest.report(command.id, argument: nil, json: json, paths: paths)
            guard try JSONEncoder().encode(request).count <= ScriptLimits.requestBytes else {
                throw fail(
                    "the paths are over the \(ScriptLimits.requestBytes) bytes a request takes;"
                        + " give fewer")
            }
            replySeconds = ScriptLimits.fileReplySeconds
        } else if let argument = rest.first {
            guard command.argument != nil else { throw fail(ScriptMessage.takesNoArgument(shown)) }
            if let problem = ScriptRequest.argumentProblem(argument) { throw fail(problem) }
        }
        if period != nil {
            guard command.id == .showStats else {
                throw fail(
                    "\(ScriptFlag.period.rawValue) only goes with \(names.name(of: .showStats))")
            }
            guard rest.isEmpty else { throw fail("\(shown) takes a period once") }
        }
        // An empty argument is none, as an empty search is no search.
        let argument = (period ?? rest.first).flatMap { $0.isEmpty ? nil : $0 }
        action = .request(
            command.takesPaths
                ? .report(command.id, argument: nil, json: json, paths: paths)
                : command.replies
                    ? .report(command.id, argument: argument, json: json)
                    : .run(command.id, argument: argument))
        if json, !command.replies {
            let replying =
                [CommandNames.Builtin.status.rawValue]
                + names.commands.filter(\.replies).map { names.name(of: $0.id) }
            throw fail(
                "\(ScriptFlag.json.rawValue) only goes with "
                    + replying.dropLast().joined(separator: ", ") + " and " + replying.last!)
        }
    }
    if action == .help, json || period != nil {
        throw fail(ScriptMessage.takesNoArgument(CommandNames.Builtin.help.rawValue))
    }
    if period != nil, case .request(.status) = action {
        throw fail("\(ScriptFlag.period.rawValue) only goes with \(names.name(of: .showStats))")
    }
    return ScriptInvocation(action: action, json: json, home: home, replySeconds: replySeconds)
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
        let usage =
            command.takesPaths
            ? "\(name) [<path>…] [\(ScriptFlag.json.rawValue)]"
            : command.replies
                ? "\(name) [\(ScriptFlag.period.rawValue) <\(command.argument ?? "")>]"
                    + " [\(ScriptFlag.json.rawValue)]"
                : command.argument.map { "\(name) [<\($0)>]" } ?? name
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
