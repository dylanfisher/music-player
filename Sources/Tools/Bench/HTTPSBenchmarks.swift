import Foundation
import HTTPSClient

/// The body the HTTPS row reads: a large Discogs cover's size.
private let bodyBytes = 3_000_000

/// The host the row asks, which a stand-in protocol answers in the process: nothing is sent
/// past it, to the network or to loopback.
private let standInHost = "bench.invalid"

let httpsBenchmarks = [
    Benchmark(
        name: "https: a 3 MB body read through HTTPSClient from a stand-in server",
        budget: Budget(appleSilicon: 50, oldMac: 200, unit: .milliseconds)
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StandInServer.self]
        let client = HTTPSClient(allowedHosts: [standInHost], configuration: configuration)
        let url = URL(string: "https://\(standInHost)/cover.jpg")!
        var read = 0
        // One read, asked from the main actor, as the tagger's covers are: a slow one takes
        // seconds a megabyte.
        let elapsed = try seconds {
            read = try onMainActor {
                try await client.get(url, headers: [:], cap: 10 << 20, timeoutSeconds: 600)
                    .body.count
            }
        }
        guard read == bodyBytes else {
            throw BenchError.expected("\(bodyBytes) bytes read: \(read)")
        }
        return Measured(
            value: elapsed * 1000,
            notes: [String(format: "%.1f ns a byte", elapsed * 1e9 / Double(bodyBytes))])
    }
]

/// Answers every request with `bodyBytes` bytes, in 64 KB pieces as a network delivers them.
/// It adds no stored state, and URLProtocol's request and client are set once, at init.
private final class StandInServer: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let piece = Data(repeating: 0xA5, count: 64 * 1024)
        var sent = 0
        while sent < bodyBytes {
            let count = min(piece.count, bodyBytes - sent)
            client?.urlProtocol(self, didLoad: piece.prefix(count))
            sent += count
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
