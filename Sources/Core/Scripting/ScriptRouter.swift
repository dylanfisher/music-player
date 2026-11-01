import Commands

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

    public init(
        dispatcher: CommandDispatcher, status: @escaping () async -> ScriptStatus,
        arguments: [CommandID: ArgumentHandler]
    ) {
        for command in dispatcher.bindings.defaults.commands where command.argument != nil {
            precondition(arguments[command.id] != nil, "\(command.id) has no argument handler")
        }
        self.dispatcher = dispatcher
        self.status = status
        self.arguments = arguments
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
