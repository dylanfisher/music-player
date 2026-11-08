import Foundation
import LocalNetwork
import Settings

/// Talks to music-recommender, the service that downloads albums from Soulseek and stages them
/// for review (ADR 0137). Every route is a POST of a JSON object with the bearer token, over
/// `LocalHTTPClient`, to an address the owner typed into Settings.
struct RecommenderClient: Sendable {
    let host: IPAddress
    let port: UInt16
    let token: ServiceToken
    let interface: NetworkInterface

    /// `address` and `port` are `recommender.address` and `recommender.port`; `interfaces`
    /// lists the interfaces that are up. Refused unless the address is another device's on one
    /// of their subnets, as `receiver.address` is (ADR 0039).
    init(address: IPAddress, port: UInt16, token: ServiceToken, interfaces: [NetworkInterface])
        throws(RecommenderError)
    {
        guard let interface = LocalSubnets(interfaces).interface(forHost: address) else {
            throw RecommenderError(service: "\(address) port \(port)", kind: .offSubnet)
        }
        host = address
        self.port = port
        self.token = token
        self.interface = interface
    }

    /// The service's version: checks the address and the token.
    func ping() async throws(RecommenderError) -> String {
        try await call("/v1/ping", body: EmptyRequest(), as: PingReply.self).version
    }

    /// Whether the downloads are on, and the format policies the service takes.
    func downloadsConfig() async throws(RecommenderError) -> DownloadsConfig {
        try await call("/v1/downloads/config", body: EmptyRequest(), as: DownloadsConfig.self)
    }

    /// Posts `body` to `path` and decodes the reply as `Reply`, or as the refusal the service
    /// gave. Any status but 200 is an error, read with its body for the code.
    func call<Request: Encodable, Reply: Decodable>(
        _ path: String, body: Request, as _: Reply.Type
    ) async throws(RecommenderError) -> Reply {
        let url: LocalURL
        do throws(LocalURL.Refusal) {
            url = try LocalURL(host: host, port: port, path: path, on: interface)
        } catch {
            preconditionFailure("the interface was checked to hold \(host): \(error)")
        }
        let fail = { (kind: RecommenderError.Kind) in
            RecommenderError(service: url.description, kind: kind)
        }
        let bytes: [UInt8]
        do {
            bytes = Array(try requestEncoder.encode(body))
        } catch {
            preconditionFailure("a request always encodes: \(error)")
        }
        let reply: [UInt8]
        do throws(LocalNetworkError) {
            reply = try await LocalHTTPClient.post(
                url,
                fields: [
                    ("Content-Type", "application/json"),
                    ("Authorization", "Bearer \(token.rawValue)"),
                ], body: bytes, keepingRefusals: true)
        } catch {
            throw fail(RecommenderError.Kind(error))
        }
        do throws(RecommenderError.Kind) {
            return try decodeReply(reply, as: Reply.self)
        } catch {
            throw fail(error)
        }
    }
}

/// Sorted keys, so a request's bytes are the same each time it's made.
let requestEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// `{}`, the body of a route that takes nothing.
struct EmptyRequest: Encodable {}

/// `ping`'s reply.
struct PingReply: Decodable {
    var version: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, version
    }

    init(from decoder: any Decoder) throws {
        let container = try okContainer(decoder, CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
    }
}
