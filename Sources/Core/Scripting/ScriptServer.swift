import Foundation
import LocalSocket

/// Answers the tool on the socket at `path`: each request is decoded strictly, run through
/// `router` on the main actor, and answered. `problem` hears what was refused and why.
@MainActor
public func startScriptServer(
    path: String, router: ScriptRouter, allowedUID: uid_t = geteuid(),
    problem: @escaping @Sendable (String) -> Void
) throws(LocalSocketError) -> LocalSocketServer {
    try LocalSocketServer(
        path: path, allowedUID: allowedUID, requestCap: ScriptLimits.requestBytes,
        timeoutSeconds: ScriptLimits.socketTimeoutSeconds,
        problem: { problem("a \(toolName) connection was refused: \($0)") },
        handler: { data, reply in
            let request: ScriptRequest
            do {
                request = try JSONDecoder().decode(ScriptRequest.self, from: data)
            } catch {
                problem("a \(toolName) request didn't decode: \(error)")
                send(.failed("the request didn't decode: \(error)"), reply, problem)
                return
            }
            Task { @MainActor in
                send(await router.handle(request, from: .commandLine), reply, problem)
            }
        })
}

private func send(_ reply: ScriptReply, _ connection: LocalSocketReply, _ problem: (String) -> Void)
{
    do {
        try connection.send(try JSONEncoder().encode(reply))
    } catch {
        problem("couldn't answer \(toolName): \(error)")
    }
}

/// Sends `request` to the app at `path` and decodes its reply, waiting at most
/// `timeoutSeconds`, and never longer than a reply that reads files may take.
public func sendScriptRequest(
    _ request: ScriptRequest, path: String, timeoutSeconds: Double = ScriptLimits.replySeconds
) throws -> ScriptReply {
    let data = try localSocketExchange(
        path: path, request: try JSONEncoder().encode(request), replyCap: ScriptLimits.replyBytes,
        timeoutSeconds: min(timeoutSeconds, ScriptLimits.fileReplySeconds))
    return try JSONDecoder().decode(ScriptReply.self, from: data)
}
