import Commands
import Foundation

/// The one query key a link takes: the command's argument.
let linkArgumentKey = "q"

/// The request a `music-player://` link asks for, or why it's refused. Any web page can open
/// a link, so it's hostile input: it runs only a command marked `runsFromLinks`, and anything
/// it doesn't spell exactly as `<scheme>://<command>[/][?q=<argument>]` is refused rather than
/// guessed at. The argument is percent-decoded once; `+` stays a plus.
public func scriptRequest(link: String, names: CommandNames) throws -> ScriptRequest {
    func refuse(_ reason: String) -> ScriptLinkRefusal { ScriptLinkRefusal(reason: reason) }
    guard link.utf8.count <= ScriptLimits.urlBytes else {
        throw refuse("it's over \(ScriptLimits.urlBytes) bytes")
    }
    let prefix = "\(urlScheme)://"
    guard link.lowercased().hasPrefix(prefix) else { throw refuse("it isn't a \(prefix) link") }
    let rest = link.dropFirst(prefix.count)
    let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    var host = parts[0]
    if host.hasSuffix("/") { host = host.dropLast() }
    guard !host.isEmpty,
        host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
    else { throw refuse("it names no command, or more than a command") }
    guard let command = names.command(named: String(host)) else {
        throw refuse(ScriptMessage.notACommand(String(host)))
    }
    let name = names.name(of: command.id)
    guard command.runsFromLinks else {
        throw refuse("\(name) doesn't run from links; use the app or `\(toolName) \(name)`")
    }
    guard parts.count == 2 else { return .run(command.id, argument: nil) }
    let pair = parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard pair.count == 2, pair[0] == linkArgumentKey, !pair[1].contains("&"),
        !pair[1].contains("#")
    else { throw refuse("its query isn't one \(linkArgumentKey)=") }
    guard command.argument != nil else { throw refuse(ScriptMessage.takesNoArgument(name)) }
    guard let argument = String(pair[1]).removingPercentEncoding else {
        throw refuse("its argument isn't percent-encoded properly")
    }
    if let problem = ScriptRequest.argumentProblem(argument) { throw refuse(problem) }
    return .run(command.id, argument: argument.isEmpty ? nil : argument)
}

/// Why a link wasn't run, for the status bar and the log.
struct ScriptLinkRefusal: Error, Equatable, CustomStringConvertible {
    let reason: String
    var description: String { "a \(urlScheme) link was refused: \(reason)" }
}
