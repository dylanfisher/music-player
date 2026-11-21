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

    let instanceID: String
    let name: String
    let page: RemotePage
    let library: RemoteLibrary
    /// The queue as it plays now.
    let queue: @Sendable () async -> RemoteQueue
    let pairing: RemotePairing
    let devices: RemoteDeviceRegistry
    let hub: RemoteEventHub
    let state: @Sendable () async -> RemoteState
    /// Runs a command through the router as `Origin.remote`.
    let run: @Sendable (CommandID, String?) async -> ScriptReply
    /// Every instance seen, this one first.
    let instances: @Sendable () -> [RemoteInstance]

    func handle(_ request: RemoteRequest) async -> RemoteResponse {
        if request.method == "GET",
            let file = page.reply(request.path, ifNoneMatch: request.field("if-none-match"))
        {
            return .reply(file)
        }
        if request.method == HTTPWord.post, request.path == RemoteRoute.pair {
            return .reply(pair(request))
        }
        guard let device = devices.device(authorization: request.field("authorization")) else {
            return .reply(RemoteReply(.unauthorized))
        }
        switch (request.method, request.path) {
        case ("GET", RemoteRoute.state):
            return .reply(Self.reply(await state()))
        case ("GET", RemoteRoute.events):
            return hub.subscribe(tokenHash: device.tokenHash)
        case (HTTPWord.post, RemoteRoute.command):
            return .reply(await command(request))
        case ("GET", RemoteRoute.instances):
            return .reply(Self.reply(instances()))
        case ("GET", RemoteRoute.queue):
            return .reply(await queueReply(RemoteQuery(request.query)))
        case ("GET", let path) where path.hasPrefix(RemoteRoute.art):
            return .reply(await art(String(path.dropFirst(RemoteRoute.art.count)), request.query))
        case ("GET", let path):
            return .reply(
                await library.reply(
                    path, query: request.query, ifNoneMatch: request.field("if-none-match"))
                    ?? RemoteReply(.notFound))
        case (_, RemoteRoute.state), (_, RemoteRoute.events), (_, RemoteRoute.command),
            (_, RemoteRoute.instances),
            (_, RemoteRoute.genres), (_, RemoteRoute.artists), (_, RemoteRoute.albums),
            (_, RemoteRoute.tracks),
            (_, RemoteRoute.search), (_, RemoteRoute.covers), (_, RemoteRoute.queue):
            return .reply(RemoteReply(.methodNotAllowed))
        default:
            return .reply(RemoteReply(.notFound))
        }
    }

    private struct QueueRange: Encodable {
        var stamp: Int
        var total: Int
        var offset: Int
        /// The current track's place in play order, from 0.
        var position: Int?
        var rows: [TrackLine]
    }

    private func queueReply(_ query: RemoteQuery) async -> RemoteReply {
        let window: Range<Int>
        do throws(RemoteRefusal) {
            try query.only([RemoteQuery.offset, RemoteQuery.limit])
            window = try query.window(limit: RemoteLibrary.rangeLimit)
        } catch {
            return Self.error(.badRequest, "\(error)")
        }
        let now = await queue()
        let shown = window.clamped(to: 0..<now.paths.count)
        do {
            return Self.reply(
                QueueRange(
                    stamp: now.stamp, total: now.paths.count, offset: window.lowerBound,
                    position: now.position,
                    rows: try await library.queueRows(Array(now.paths[shown]))))
        } catch {
            return Self.error(.serviceUnavailable, "the queue's tracks couldn't be read: \(error)")
        }
    }

    /// A cover, `<size>/<id>`, kept by the phone for good: its ID changes when the picture
    /// does.
    private func art(_ rest: String, _ query: String?) async -> RemoteReply {
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard query == nil, parts.count == 2 else { return RemoteReply(.notFound) }
        do {
            guard let found = try await library.art(String(parts[1]), size: String(parts[0]))
            else { return RemoteReply(.notFound) }
            return RemoteReply(
                .ok, contentType: found.type, body: Array(found.bytes),
                fields: [(HTTPWord.cacheControl, "private, max-age=31536000, immutable")])
        } catch {
            return Self.error(.serviceUnavailable, "the cover couldn't be read: \(error)")
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

/// The web remote's paths.
public enum RemoteRoute {
    static let pair = "/api/pair"
    static let state = "/api/state"
    static let events = "/api/events"
    static let command = "/api/command"
    static let instances = "/api/instances"
    public static let genres = "/api/genres"
    public static let artists = "/api/artists"
    static let albums = "/api/albums"
    public static let tracks = "/api/tracks"
    public static let search = "/api/search"
    static let covers = "/api/covers"
    static let queue = "/api/queue"
    /// Followed by a size, `/` and a cover's ID.
    static let art = "/api/art/"
}
