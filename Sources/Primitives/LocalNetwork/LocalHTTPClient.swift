import Foundation
import Network

/// Fetches from devices on a local subnet: GET and POST to a `LocalURL` only, on
/// `NWConnection` rather than URLSession, so no proxy, cache or redirect sits between the app
/// and the checks (ADR 0039). A redirect is a status like any other than 200, and refused.
public enum LocalHTTPClient {
    /// Most bytes a body may have.
    public static let bodyCap = 1024 * 1024
    /// Longest a whole exchange may take, connecting included.
    public static let timeoutSeconds = 5.0
    /// Most bytes a reply's head may have.
    static let headCap = 64 * 1024

    public static func get(
        _ url: LocalURL, cap: Int = bodyCap, timeoutSeconds: Double = timeoutSeconds
    ) async throws(LocalNetworkError) -> [UInt8] {
        try await exchange(
            url, request: request("GET", url, fields: [], body: []), cap: cap,
            timeoutSeconds: timeoutSeconds)
    }

    /// Posts `body` with `fields` besides `Host`, `Connection` and `Content-Length`.
    public static func post(
        _ url: LocalURL, fields: [(String, String)], body: [UInt8], cap: Int = bodyCap,
        timeoutSeconds: Double = timeoutSeconds
    ) async throws(LocalNetworkError) -> [UInt8] {
        try await exchange(
            url, request: request("POST", url, fields: fields, body: body), cap: cap,
            timeoutSeconds: timeoutSeconds)
    }

    static func request(
        _ method: String, _ url: LocalURL, fields: [(String, String)], body: [UInt8]
    )
        -> [UInt8]
    {
        var lines = [
            "\(method) \(url.target) \(HTTPHead.version)", "Host: \(url.authority)",
            "Connection: close",
        ]
        for (name, value) in fields {
            precondition(
                (name + value).utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }, "\(name) can't be sent")
            lines.append("\(name): \(value)")
        }
        if method == "POST" { lines.append("Content-Length: \(body.count)") }
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    private static func exchange(
        _ url: LocalURL, request: [UInt8], cap: Int, timeoutSeconds: Double
    ) async throws(LocalNetworkError) -> [UInt8] {
        let outcome = await withCheckedContinuation { continuation in
            Exchange(url: url, cap: cap, continuation: continuation).start(
                request, timeoutSeconds: timeoutSeconds)
        }
        return try outcome.get()
    }
}

/// One request and its reply. Its state is touched only on `queue`.
private final class Exchange: @unchecked Sendable {
    typealias Outcome = Result<[UInt8], LocalNetworkError>

    private let queue = DispatchQueue(label: "LocalHTTPClient")
    private let connection: NWConnection
    private let cap: Int
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var received: [UInt8] = []
    private var head: (head: HTTPHead, length: Int)?

    init(url: LocalURL, cap: Int, continuation: CheckedContinuation<Outcome, Never>) {
        connection = NWConnection(
            host: url.host.endpointHost, port: NWEndpoint.Port(rawValue: url.port)!,
            using: directTCP())
        self.cap = cap
        self.continuation = continuation
    }

    func start(_ request: [UInt8], timeoutSeconds: Double) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(
                    content: Data(request),
                    completion: .contentProcessed { [self] error in
                        if let error { finish(.failure(.failed("\(error)"))) }
                    })
                receive()
            case .waiting(let error): finish(.failure(.refused("\(error)")))
            case .failed(let error) where error == .posix(.ECONNREFUSED):
                finish(.failure(.refused("\(error)")))
            case .failed(let error): finish(.failure(.failed("\(error)")))
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeoutSeconds) { [self] in
            finish(.failure(.timedOut))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [self] data, _, isComplete, error in
            if let data { received += data }
            if let outcome = progress(closed: isComplete || error != nil) {
                finish(outcome)
            } else if let error {
                finish(.failure(.failed("\(error)")))
            } else {
                receive()
            }
        }
    }

    /// The outcome once the bytes so far settle it; nil while more are needed.
    private func progress(closed: Bool) -> Outcome? {
        if head == nil {
            switch HTTPHead.parse(received[...], cap: LocalHTTPClient.headCap) {
            case .incomplete:
                return closed ? .failure(.malformed("it ended inside its head")) : nil
            case .tooLarge: return .failure(.tooLarge(cap: LocalHTTPClient.headCap))
            case .malformed(let why): return .failure(.malformed(why))
            case .head(let parsed, let length):
                guard parsed.start[0].hasPrefix("HTTP/1."), let status = Int(parsed.start[1]) else {
                    return .failure(.malformed("its status line is \(parsed.start)"))
                }
                guard status == 200 else { return .failure(.status(status)) }
                head = (parsed, length)
            }
        }
        guard let (head, length) = head else { return nil }
        let body = received[length...]
        let encodings = head.values(HTTPHead.transferEncoding)
        if !encodings.isEmpty {
            guard encodings.count == 1, encodings[0].lowercased() == "chunked" else {
                return .failure(.malformed("its transfer encoding is \(encodings)"))
            }
            // Chunk lines and extensions aside, the encoded body can't be much over the cap.
            guard body.count <= 2 * cap else { return .failure(.tooLarge(cap: cap)) }
            switch decodeChunked(body, cap: cap) {
            case .incomplete:
                return closed ? .failure(.malformed("it ended inside a chunk")) : nil
            case .tooLarge: return .failure(.tooLarge(cap: cap))
            case .malformed(let why): return .failure(.malformed(why))
            case .done(let decoded): return .success(decoded)
            }
        }
        let lengths = head.values(HTTPHead.contentLength)
        if !lengths.isEmpty {
            guard lengths.count == 1, let declared = Int(lengths[0]), declared >= 0,
                lengths[0].allSatisfy(\.isASCII)
            else { return .failure(.malformed("its Content-Length is \(lengths)")) }
            guard declared <= cap else { return .failure(.tooLarge(cap: cap)) }
            if body.count >= declared { return .success(Array(body.prefix(declared))) }
            return closed ? .failure(.malformed("it ended before its Content-Length")) : nil
        }
        guard body.count <= cap else { return .failure(.tooLarge(cap: cap)) }
        return closed ? .success(Array(body)) : nil
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: outcome)
    }
}

/// What a chunked body decodes to so far.
public enum Chunked: Equatable, Sendable {
    case incomplete
    case tooLarge
    case malformed(String)
    case done([UInt8])
}

/// Decodes a chunked body from its start. Extensions and trailers are skipped. A size is hex
/// digits alone: `Int(_:radix:)` would take a sign, and a negative size would cut the body
/// backwards.
public func decodeChunked(_ bytes: ArraySlice<UInt8>, cap: Int) -> Chunked {
    var decoded: [UInt8] = []
    var index = bytes.startIndex
    func line() -> ArraySlice<UInt8>? {
        guard let end = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        var text = bytes[index..<end]
        if text.last == UInt8(ascii: "\r") { text = text.dropLast() }
        index = end + 1
        return text
    }
    while true {
        guard let sizeLine = line() else { return .incomplete }
        let digits = sizeLine.prefix { $0 != UInt8(ascii: ";") }
        guard !digits.isEmpty, digits.count <= 8, digits.allSatisfy(isHexDigit),
            let size = Int(String(decoding: digits, as: UTF8.self), radix: 16)
        else { return .malformed("a chunk's size isn't hex") }
        if size == 0 {
            while true {
                guard let trailer = line() else { return .incomplete }
                if trailer.isEmpty { return .done(decoded) }
            }
        }
        guard decoded.count + size <= cap else { return .tooLarge }
        guard bytes.endIndex - index >= size else { return .incomplete }
        decoded += bytes[index..<(index + size)]
        index += size
        guard let end = line() else { return .incomplete }
        guard end.isEmpty else { return .malformed("a chunk runs past its size") }
    }
}

private func isHexDigit(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"),
        UInt8(ascii: "A")...UInt8(ascii: "F"):
        true
    default:
        false
    }
}
