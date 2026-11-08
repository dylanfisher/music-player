import Foundation
import Testing

@testable import HTTPSClient

/// What the stub protocol answers a request with.
private enum Reply: Sendable {
    case response(status: Int, headers: [String: String], body: [UInt8])
    case redirect(to: URL)
    case failure(URLError.Code)
    /// Never answers, until the task is cancelled.
    case silence
}

/// Answers requests from the replies registered for their path, and records each request, so
/// no test opens a socket. Paths are unique per test, so tests run in parallel.
private final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requests: [String: [URLRequest]] = [:]
    static let lock = NSLock()

    static func register(_ reply: Reply) -> URL {
        let path = "/" + UUID().uuidString
        lock.withLock { replies[path] = reply }
        return URL(string: "https://api.example.com\(path)")!
    }

    static func requests(to url: URL) -> [URLRequest] {
        lock.withLock { requests.filter { $0.key.hasPrefix(url.path) }.flatMap(\.value) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        let reply = Self.lock.withLock {
            Self.requests[path, default: []].append(request)
            return Self.replies[path]
        }
        switch reply {
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // In pieces, as a network delivers it.
            var offset = 0
            while offset < body.count {
                let end = min(offset + 64 * 1024, body.count)
                client?.urlProtocol(self, didLoad: Data(body[offset..<end]))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .silence, nil:
            break
        }
    }

    override func stopLoading() {}
}

private func client() -> HTTPSClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [Stub.self]
    return HTTPSClient(allowedHosts: ["api.example.com"], configuration: configuration)
}

private func get(
    _ url: URL, headers: [String: String] = [:], cap: Int = 1024, timeoutSeconds: Double = 5
) async throws(HTTPSError) -> HTTPSResponse {
    try await client().get(url, headers: headers, cap: cap, timeoutSeconds: timeoutSeconds)
}

@Test func aGetReturnsTheStatusHeadersAndBodyAndSendsTheHeaders() async throws {
    let url = Stub.register(
        .response(status: 200, headers: ["X-Discogs-Ratelimit": "60"], body: Array("{}".utf8)))
    let response = try await get(url, headers: ["User-Agent": "MusicPlayer/1"])
    #expect(response.status == 200)
    #expect(response.header("x-discogs-ratelimit") == "60")
    #expect(response.body == Array("{}".utf8))
    let sent = Stub.requests(to: url)
    #expect(sent.count == 1)
    #expect(sent.first?.value(forHTTPHeaderField: "User-Agent") == "MusicPlayer/1")
    #expect(sent.first?.httpMethod == "GET")
}

@Test func anyStatusComesBackAsItIs() async throws {
    for status in [404, 429, 500] {
        let url = Stub.register(.response(status: status, headers: [:], body: []))
        #expect(try await get(url).status == status)
    }
}

@Test func onlyHTTPSOnPort443ToAnAllowedHostIsSent() async throws {
    let allowed = Stub.register(.response(status: 200, headers: [:], body: []))
    for text in [
        "http://api.example.com\(allowed.path)",
        "https://api.example.com:8443\(allowed.path)",
        "https://user@api.example.com\(allowed.path)",
        "https://user:pass@api.example.com\(allowed.path)",
        "https://example.com\(allowed.path)",
        "https://api.example.com.evil.net\(allowed.path)",
        "ftp://api.example.com\(allowed.path)",
    ] {
        await #expect(throws: HTTPSError.refusedAddress, "\(text)") {
            try await get(URL(string: text)!)
        }
    }
    #expect(Stub.requests(to: allowed).isEmpty)
    #expect(try await get(URL(string: "https://API.example.com:443\(allowed.path)")!).status == 200)
}

@Test func aRedirectIsNeverFollowed() async throws {
    let target = Stub.register(.response(status: 200, headers: [:], body: Array("x".utf8)))
    let url = Stub.register(.redirect(to: target))
    #expect(try await get(url).status == 302)
    #expect(Stub.requests(to: target).isEmpty)
}

@Test func aBodyPastItsCapIsRefused() async throws {
    let streamed = Stub.register(
        .response(status: 200, headers: [:], body: Array(repeating: 0x41, count: 300_000)))
    await #expect(throws: HTTPSError.tooLarge(cap: 100_000)) {
        try await get(streamed, cap: 100_000)
    }
    let declared = Stub.register(
        .response(status: 200, headers: ["Content-Length": "5000000"], body: Array("x".utf8)))
    await #expect(throws: HTTPSError.tooLarge(cap: 1024)) { try await get(declared) }
    let exact = Stub.register(
        .response(status: 200, headers: [:], body: Array(repeating: 0x41, count: 1024)))
    #expect(try await get(exact).body.count == 1024)
}

@Test func aRequestPastItsTimeoutFails() async throws {
    let url = Stub.register(.silence)
    let started = Date()
    await #expect(throws: HTTPSError.timedOut) { try await get(url, timeoutSeconds: 0.2) }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func cancellingTheTaskStopsTheRequest() async throws {
    let url = Stub.register(.silence)
    let task = Task { () async -> HTTPSError? in
        do throws(HTTPSError) {
            _ = try await get(url, timeoutSeconds: 30)
            return nil
        } catch {
            return error
        }
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    #expect(await task.value == .cancelled)
}

@Test func networkFailuresMapToTheirErrors() async throws {
    for (code, error) in [
        (URLError.Code.notConnectedToInternet, HTTPSError.offline), (.cannotFindHost, .offline),
        (.timedOut, .timedOut), (.secureConnectionFailed, .insecure(code: -1200)),
        (.serverCertificateUntrusted, .insecure(code: -1202)), (.badURL, .failed(code: -1000)),
    ] {
        let url = Stub.register(.failure(code))
        await #expect(throws: error) { try await get(url) }
    }
}

@Test func noErrorTextHoldsAnAddressOrAHeader() {
    for error in [
        HTTPSError.refusedAddress, .offline, .timedOut, .tooLarge(cap: 4), .cancelled,
        .insecure(code: -1202), .failed(code: -1200),
    ] {
        #expect(!error.description.contains("http"))
        #expect(!error.description.contains("example"))
    }
}
