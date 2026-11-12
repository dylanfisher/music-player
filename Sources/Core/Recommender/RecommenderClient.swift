import Foundation
import LocalNetwork
import Settings

/// Talks to music-recommender, the service that downloads albums from Soulseek and stages them
/// for review (ADR 0145). Every route is a POST of a JSON object with the bearer token, over
/// `LocalHTTPClient`, to an address the owner typed into Settings.
package struct RecommenderClient: Sendable {
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

    /// The client for `address` and `port` on the interfaces up now, which App makes for each
    /// call, so a network that comes up later is found.
    package init(address: IPAddress, port: UInt16, token: ServiceToken)
        throws(RecommenderError)
    {
        let interfaces: [NetworkInterface]
        do throws(LocalNetworkError) {
            interfaces = try currentInterfaces()
        } catch {
            throw RecommenderError(service: "\(address) port \(port)", kind: .unreachable(error))
        }
        try self.init(address: address, port: port, token: token, interfaces: interfaces)
    }

    /// Posts `body` to `path` and decodes the reply as `Reply`, or as the refusal the service
    /// gave. Any status but 200 is an error, read with its body for the code. `timeoutSeconds`
    /// is the whole exchange's; only a route that computes before it answers takes longer.
    func call<Request: Encodable, Reply: Decodable>(
        _ path: String, body: Request, as _: Reply.Type,
        timeoutSeconds: Double = LocalHTTPClient.timeoutSeconds
    ) async throws(RecommenderError) -> Reply {
        let url = url(path)
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
                    ("Authorization", "Bearer \(token.secret)"),
                ], body: bytes, timeoutSeconds: timeoutSeconds, keepingRefusals: true)
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

extension RecommenderClient {
    /// The URL of the route at `path`.
    func url(_ path: String) -> LocalURL {
        do throws(LocalURL.Refusal) {
            return try LocalURL(host: host, port: port, path: path, on: interface)
        } catch {
            preconditionFailure("the interface was checked to hold \(host): \(error)")
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
