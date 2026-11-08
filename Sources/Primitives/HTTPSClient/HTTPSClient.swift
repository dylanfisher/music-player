import Foundation

/// GETs over HTTPS from a fixed set of hosts, for the app's internet connections (ADR 0138).
/// It uses URLSession, for TLS, HTTP/2 and the system's proxy settings, in an ephemeral session
/// with no cache, cookies or stored credentials. A URL that isn't https on port 443 to one of
/// `allowedHosts`, or that carries a user, is refused before anything is sent. Redirects are
/// never followed: a 3xx comes back as its status. A body is read as it arrives and dropped
/// past its cap, and a request that takes longer than its timeout fails.
public final class HTTPSClient: Sendable {
    public let allowedHosts: Set<String>
    private let session: URLSession
    private let refuser = RedirectRefuser()

    /// `configuration` is ephemeral unless a caller gives another; tests give one with a stub
    /// protocol. Whatever it is, caching, cookies and stored credentials are turned off in it.
    public init(
        allowedHosts: Set<String>, configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.allowedHosts = allowedHosts
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: refuser, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Whether `url` is one `get` would send: https, port 443 or none, no user or password, a
    /// host in `allowedHosts`.
    public func allows(_ url: URL) -> Bool { Self.allows(url, hosts: allowedHosts) }

    /// Whether `url` is https, on port 443 or none, with no user or password, to one of
    /// `hosts`, which are lowercase.
    public static func allows(_ url: URL, hosts: Set<String>) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
            parts.port == nil || parts.port == 443,
            let host = parts.host?.lowercased(), hosts.contains(host)
        else { return false }
        return true
    }

    /// GETs `url` with `headers`, whose names and values must be printable ASCII. The body
    /// may be at most `cap` bytes, after any decompression, and the whole request takes at
    /// most `timeoutSeconds`.
    public func get(
        _ url: URL, headers: [String: String], cap: Int, timeoutSeconds: Double
    ) async throws(HTTPSError) -> HTTPSResponse {
        guard allows(url) else { throw .refusedAddress }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "GET"
        for (name, value) in headers {
            precondition(
                (name + value).utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F },
                "the \(name) header can't be sent")
            request.setValue(value, forHTTPHeaderField: name)
        }
        let prepared = request
        do {
            return try await withThrowingTaskGroup(of: HTTPSResponse?.self) { group in
                group.addTask { [self] in try await fetch(prepared, cap: cap) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let response = first else {
                    throw HTTPSError.timedOut
                }
                return response
            }
        } catch let error as HTTPSError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError {
            throw Self.error(error)
        } catch {
            throw .failed(code: URLError.unknown.rawValue)
        }
    }

    private func fetch(_ request: URLRequest, cap: Int) async throws -> HTTPSResponse {
        let (bytes, response) = try await session.bytes(for: request, delegate: refuser)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // A redirect is refused in the delegate; this catches one that got through anyway.
        guard let final = response.url, allows(final) else { throw HTTPSError.refusedAddress }
        if response.expectedContentLength > cap { throw HTTPSError.tooLarge(cap: cap) }
        var body: [UInt8] = []
        body.reserveCapacity(min(max(Int(response.expectedContentLength), 0), cap))
        for try await byte in bytes {
            guard body.count < cap else { throw HTTPSError.tooLarge(cap: cap) }
            body.append(byte)
        }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return HTTPSResponse(status: response.statusCode, headers: headers, body: body)
    }

    static func error(_ error: URLError) -> HTTPSError {
        switch error.code {
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
            .dataNotAllowed, .callIsActive:
            .offline
        default: .failed(code: error.code.rawValue)
        }
    }
}

/// Answers every redirect with nil, so the 3xx is the response.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
