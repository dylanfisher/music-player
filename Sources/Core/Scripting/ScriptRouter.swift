import Commands
import Foundation

/// Runs requests from the tool and from links through the registry, as a menu item or the
/// palette would, and says what came of each.
@MainActor
public final class ScriptRouter {
    public enum Origin: Sendable {
        /// The socket: this user's own processes, so any command.
        case commandLine
        /// A `music-player://` link: only commands marked `runsFromLinks`.
        case link
    }

    /// Runs a command's argument; each command declaring one has one.
    public typealias ArgumentHandler = (String) async throws -> String?

    private let dispatcher: CommandDispatcher
    private let status: () async -> ScriptStatus
    private let arguments: [CommandID: ArgumentHandler]
    private let names: CommandNames
    private var linkRate: LinkRate

    /// `now` is seconds on any steady clock, injected so tests needn't wait.
    public init(
        dispatcher: CommandDispatcher, status: @escaping () async -> ScriptStatus,
        arguments: [CommandID: ArgumentHandler],
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        for command in dispatcher.bindings.defaults.commands where command.argument != nil {
            precondition(arguments[command.id] != nil, "\(command.id) has no argument handler")
        }
        self.dispatcher = dispatcher
        self.status = status
        self.arguments = arguments
        names = CommandNames(dispatcher.bindings.defaults.commands)
        linkRate = LinkRate(now: now)
    }

    /// Runs a `music-player://` link: refused past `LinkRate.perSecond` a second, whatever
    /// they ask, and then refused unless it has the exact shape and names a command marked
    /// `runsFromLinks`.
    public func link(_ text: String) async -> ScriptReply {
        guard linkRate.allow() else {
            return .failed(
                "over \(LinkRate.perSecond) links in a second came, and this one was refused")
        }
        do {
            return await handle(try scriptRequest(link: text, names: names), from: .link)
        } catch {
            return .failed("\(error)")
        }
    }

    public func handle(_ request: ScriptRequest, from origin: Origin) async -> ScriptReply {
        switch request {
        case .status:
            guard origin == .commandLine else { return .failed("a link can't ask for the status") }
            return .status(await status())
        case .run(let id, let argument):
            guard let command = dispatcher.bindings.defaults.command(id) else {
                return .failed(ScriptMessage.notACommand(id.rawValue))
            }
            if origin == .link, !command.runsFromLinks {
                return .failed("\(id) doesn't run from links")
            }
            guard let argument else {
                return dispatcher.run(id) ? .done(nil) : .failed("\(command.title) can't run now")
            }
            guard command.argument != nil, let handler = arguments[id] else {
                return .failed(ScriptMessage.takesNoArgument(id.rawValue))
            }
            if let problem = ScriptRequest.argumentProblem(argument) { return .failed(problem) }
            do {
                return .done(try await handler(argument))
            } catch {
                return .failed("\(error)")
            }
        }
    }
}

/// How many links run in any second. A web page can open links in a loop, so past this they're
/// refused: Next can't skip through an album, nor Volume Down mute it, faster than this.
struct LinkRate {
    static let perSecond = 5

    private let now: () -> Double
    /// When the latest links that ran came, oldest first, at most `perSecond` of them.
    private var times: [Double] = []

    init(now: @escaping () -> Double) { self.now = now }

    mutating func allow() -> Bool {
        let time = now()
        times.removeAll { time - $0 >= 1 }
        guard times.count < Self.perSecond else { return false }
        times.append(time)
        return true
    }
}
