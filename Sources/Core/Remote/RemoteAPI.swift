import Commands
import Foundation
import LocalNetwork
import Scripting
import Settings
import StrictKeys

/// The web remote's routes (ADR 0214). The page and the code trade answer anyone the server
/// lets through; every other path needs a paired device's bearer token, and without one gets a
/// 401 with nothing in it, whatever the path, so a stranger learns no route.
struct RemoteAPI: Sendable {
    enum Route {
        static let page = "/"
        static let pageFile = "/index.html"
        static let pair = "/api/pair"
        static let state = "/api/state"
        static let events = "/api/events"
        static let command = "/api/command"
        static let instances = "/api/instances"
    }

    let instanceID: String
    let name: String
    let page: [UInt8]
    let pairing: RemotePairing
    let devices: RemoteDeviceRegistry
    let hub: RemoteEventHub
    let state: @Sendable () async -> RemoteState
    /// Runs a command through the router as `Origin.remote`.
    let run: @Sendable (CommandID, String?) async -> ScriptReply
    /// Every instance seen, this one first.
    let instances: @Sendable () -> [RemoteInstance]

    func handle(_ request: RemoteRequest) async -> RemoteResponse {
        switch (request.method, request.path) {
        case ("GET", Route.page), ("GET", Route.pageFile):
            return .reply(
                RemoteReply(
                    .ok, contentType: "text/html; charset=utf-8", body: page,
                    fields: [(HTTPWord.cacheControl, "no-cache")]))
        case (HTTPWord.post, Route.pair):
            return .reply(pair(request))
        default:
            break
        }
        guard let device = devices.device(authorization: request.field("authorization")) else {
            return .reply(RemoteReply(.unauthorized))
        }
        switch (request.method, request.path) {
        case ("GET", Route.state):
            return .reply(Self.reply(await state()))
        case ("GET", Route.events):
            return hub.subscribe(tokenHash: device.tokenHash)
        case (HTTPWord.post, Route.command):
            return .reply(await command(request))
        case ("GET", Route.instances):
            return .reply(Self.reply(instances()))
        case (_, Route.state), (_, Route.events), (_, Route.command), (_, Route.instances):
            return .reply(RemoteReply(.methodNotAllowed))
        default:
            return .reply(RemoteReply(.notFound))
        }
    }

    private struct PairRequest: Decodable {
        var code: String
        var device: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case code, device
        }

        init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            code = try container.decode(String.self, forKey: .code)
            device = try container.decode(String.self, forKey: .device)
        }
    }

    private struct Paired: Encodable {
        var token: String
        var instance: String
        var name: String
    }

    private func pair(_ request: RemoteRequest) -> RemoteReply {
        let asked: PairRequest
        switch Self.decode(PairRequest.self, request) {
        case .success(let decoded): asked = decoded
        case .failure(let refusal): return refusal.reply
        }
        if let problem = RemoteDevices.Device.nameProblem(asked.device) {
            return Self.error(.badRequest, "the device name is refused: \(problem)")
        }
        do throws(RemotePairing.Refusal) {
            try pairing.trade(asked.code)
        } catch {
            return Self.error(.forbidden, "\(error)")
        }
        do {
            let token = try devices.pair(name: asked.device)
            return Self.reply(Paired(token: token, instance: instanceID, name: name))
        } catch {
            return Self.error(.serviceUnavailable, "the Mac couldn't save the pairing: \(error)")
        }
    }

    private struct CommandRequest: Decodable {
        var name: String
        var argument: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name, argument
        }

        init(from decoder: any Decoder) throws {
            let container = try strictContainer(decoder, CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            argument = try container.decodeIfPresent(String.self, forKey: .argument)
        }
    }

    private struct Ran: Encodable {
        var message: String?
    }

    private func command(_ request: RemoteRequest) async -> RemoteReply {
        let asked: CommandRequest
        switch Self.decode(CommandRequest.self, request) {
        case .success(let decoded): asked = decoded
        case .failure(let refusal): return refusal.reply
        }
        switch await run(CommandID(asked.name), asked.argument) {
        case .done(let message): return Self.reply(Ran(message: message))
        case .failed(let reason): return Self.error(.badRequest, reason)
        case .status: preconditionFailure("running a command never replies with the status")
        }
    }

    /// The body as `T`, strictly: JSON only, every key known, none missing.
    private static func decode<T: Decodable>(_ type: T.Type, _ request: RemoteRequest)
        -> Result<T, Refused>
    {
        let mediaType = request.field("content-type")?.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard mediaType == HTTPWord.json else {
            return .failure(
                Refused(reply: error(.unsupportedMediaType, "the body must be \(HTTPWord.json)")))
        }
        do {
            return .success(try JSONDecoder().decode(T.self, from: Data(request.body)))
        } catch {
            return .failure(
                Refused(reply: Self.error(.badRequest, "the body didn't decode: \(error)")))
        }
    }

    private struct Failure: Encodable {
        var error: String
    }

    static func error(_ status: HTTPStatus, _ reason: String) -> RemoteReply {
        var made = reply(Failure(error: reason))
        made.status = status
        return made
    }

    static func reply(_ value: some Encodable) -> RemoteReply {
        do {
            return RemoteReply(
                .ok, contentType: HTTPWord.json, body: try remoteJSON(value),
                fields: [(HTTPWord.cacheControl, HTTPWord.noStore)])
        } catch {
            return RemoteReply(
                .serviceUnavailable, contentType: "text/plain; charset=utf-8",
                body: Array("the reply couldn't be encoded: \(error)".utf8))
        }
    }
}

/// A request refused before it's acted on, with the reply that says why.
private struct Refused: Error {
    var reply: RemoteReply
}
