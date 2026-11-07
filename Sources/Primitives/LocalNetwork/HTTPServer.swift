import Darwin
import Foundation
import Network

/// A file the server may send: an absolute path, opened read-only without following a link,
/// and the type a renderer is told.
public struct HTTPServedFile: Sendable, Equatable {
    public let path: String
    public let contentType: String

    public init(path: String, contentType: String) {
        self.path = path
        self.contentType = contentType
    }
}

/// Serves files to one device on a local subnet by token (ADR 0039, 0041). It listens on one
/// interface's address, on a port the system picks, and takes connections only from that one
/// device's address on that interface's subnet. A URL names a random token, which maps to a key, which `resolve` maps to a file at
/// request time; an unknown token is 404 before `resolve` or the file system sees it. Requests
/// are `GET` or `HEAD` with the bound address as `Host`, no body and at most one range. At most
/// `connectionCap` connections at once, each closed when its request head isn't whole within
/// `headSeconds`, however slowly it trickles in, after `idleSeconds` without progress before
/// its reply's body starts, and after its one reply.
///
/// 9b's UPnP output is its caller: it starts a server when a renderer is chosen and stops it
/// when none is in use.
public final class HTTPServer<Key: Hashable & Sendable>: @unchecked Sendable {
    public typealias Resolve = @Sendable (Key) -> HTTPServedFile?

    static var requestHeadCap: Int { 8 * 1024 }
    static var connectionCap: Int { 8 }
    static var idleSeconds: Double { 30 }
    static var headSeconds: Double { 10 }
    static var listenSeconds: Double { 5 }
    static var tokenLifetimeSeconds: Double { 24 * 60 * 60 }
    static var chunkBytes: Int { 64 * 1024 }

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "HTTPServer")
    private let listener: NWListener
    private let interface: NetworkInterface
    private let accepts: @Sendable (IPAddress) -> Bool
    private let resolve: Resolve
    private let problem: @Sendable (String) -> Void
    private let now: @Sendable () -> Double
    private let idleSeconds: Double
    private let headSeconds: Double
    private var tokens = TokenMap<Key>(lifetimeSeconds: tokenLifetimeSeconds)
    private var clients: [ObjectIdentifier: Client] = [:]
    private var boundPort: UInt16 = 0
    private var listening: CheckedContinuation<Result<Void, LocalNetworkError>, Never>?

    /// Starts a server on `interface`'s address that takes connections only from `peer`, the
    /// one device it serves, so another host on the subnet holding a token gets nothing.
    /// `problem` hears each connection refused and each file that couldn't be served.
    public static func start(
        on interface: NetworkInterface, acceptingOnly peer: IPAddress,
        resolve: @escaping Resolve, problem: @escaping @Sendable (String) -> Void
    ) async throws(LocalNetworkError) -> HTTPServer {
        try await start(
            on: interface, accepts: { interface.holds($0) && $0 == peer }, resolve: resolve,
            problem: problem)
    }

    static func start(
        on interface: NetworkInterface, accepts: @escaping @Sendable (IPAddress) -> Bool,
        resolve: @escaping Resolve, problem: @escaping @Sendable (String) -> Void,
        idleSeconds: Double = idleSeconds, headSeconds: Double = headSeconds,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async throws(LocalNetworkError) -> HTTPServer {
        let server = try HTTPServer(
            interface: interface, accepts: accepts, resolve: resolve, problem: problem,
            idleSeconds: idleSeconds, headSeconds: headSeconds, now: now)
        try await server.listen()
        return server
    }

    private init(
        interface: NetworkInterface, accepts: @escaping @Sendable (IPAddress) -> Bool,
        resolve: @escaping Resolve, problem: @escaping @Sendable (String) -> Void,
        idleSeconds: Double, headSeconds: Double, now: @escaping @Sendable () -> Double
    ) throws(LocalNetworkError) {
        let parameters = directTCP()
        parameters.requiredLocalEndpoint = .hostPort(
            host: interface.address.endpointHost, port: .any)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .failed("can't listen on \(interface.address): \(error)")
        }
        self.interface = interface
        self.accepts = accepts
        self.resolve = resolve
        self.problem = problem
        self.idleSeconds = idleSeconds
        self.headSeconds = headSeconds
        self.now = now
    }

    private func listen() async throws(LocalNetworkError) {
        let outcome = await withCheckedContinuation { continuation in
            queue.sync { listening = continuation }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        listener.cancel()
                        return endListening(
                            .failure(.failed("can't listen on \(interface.address): no port")))
                    }
                    boundPort = port
                    endListening(.success(()))
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    endListening(
                        .failure(.failed("can't listen on \(interface.address): \(error)")))
                case .cancelled:
                    endListening(.failure(.cancelled))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in accept(connection) }
            listener.start(queue: queue)
            // Without a bound, a listener that never reports a state leaves the caller waiting.
            queue.asyncAfter(deadline: .now() + Self.listenSeconds) { [self] in
                guard listening != nil else { return }
                listener.cancel()
                endListening(.failure(.timedOut))
            }
        }
        try outcome.get()
    }

    private func endListening(_ outcome: Result<Void, LocalNetworkError>) {
        listening?.resume(returning: outcome)
        listening = nil
    }

    /// The port the system picked.
    public var port: UInt16 { queue.sync { boundPort } }

    /// The URL that serves `key` for this session: the same until its token is a day old.
    public func url(for key: Key) -> String {
        queue.sync {
            "http://\(authority)/" + tokens.token(for: key, now: now())
        }
    }

    /// Stops listening and closes every connection. Tokens end with it.
    public func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.cancel()
            for client in clients.values { end(client) }
        }
    }

    /// The `Host` a request must send: the bound address and port.
    private var authority: String { "\(interface.address.urlHost):\(boundPort)" }

    private func accept(_ connection: NWConnection) {
        guard let peer = IPAddress(peerOf: connection), accepts(peer) else {
            problem("refused a connection from \(connection.endpoint), off \(interface)")
            connection.cancel()
            return
        }
        guard clients.count < Self.connectionCap else {
            problem("refused a connection from \(peer): \(Self.connectionCap) are open")
            connection.cancel()
            return
        }
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: end(client)
            default: break
            }
        }
        connection.start(queue: queue)
        touch(client)
        queue.asyncAfter(deadline: .now() + headSeconds) { [self] in
            if !client.hasHead { end(client) }
        }
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.requestHeadCap) {
            [self] data, _, isComplete, error in
            guard clients[ObjectIdentifier(client)] != nil else { return }
            if let data { client.received += data }
            touch(client)
            switch HTTPHead.parse(client.received[...], cap: Self.requestHeadCap) {
            case .incomplete:
                if isComplete || error != nil { end(client) } else { receive(client) }
            case .tooLarge: reply(client, .headersTooLarge)
            case .malformed: reply(client, .badRequest)
            case .head(let head, let length):
                client.hasHead = true
                answer(client, head, extra: client.received.count - length)
            }
        }
    }

    private func answer(_ client: Client, _ head: HTTPHead, extra: Int) {
        let token: String
        let range: ByteRangeRequest?
        let sendsBody: Bool
        switch route(head, extra: extra, authority: authority) {
        case .refuse(let status):
            reply(client, status)
            return
        case .serve(let routed, let ranged, let body):
            (token, range, sendsBody) = (routed, ranged, body)
        }
        guard let key = tokens.key(for: token, now: now()), let file = resolve(key) else {
            reply(client, .notFound)
            return
        }
        let opened: OpenFile
        do throws(LocalNetworkError) {
            opened = try OpenFile(file.path)
        } catch {
            problem("couldn't serve a file: \(error)")
            reply(client, .notFound)
            return
        }
        client.file = opened
        var fields = [
            ("Content-Type", file.contentType), ("Accept-Ranges", "bytes"),
        ]
        let bytes: ClosedRange<UInt64>?
        let status: HTTPStatus
        if let range {
            guard let inFile = range.bytes(inFileOf: opened.size) else {
                reply(client, .rangeNotSatisfiable, [("Content-Range", "bytes */\(opened.size)")])
                return
            }
            bytes = inFile
            status = .partialContent
            fields.append(
                ("Content-Range", "bytes \(inFile.lowerBound)-\(inFile.upperBound)/\(opened.size)"))
        } else {
            bytes = opened.size == 0 ? nil : 0...(opened.size - 1)
            status = .ok
        }
        let length = bytes.map { $0.upperBound - $0.lowerBound + 1 } ?? 0
        let headBytes = responseHead(status, fields: fields, length: length)
        guard sendsBody, let bytes else {
            client.connection.send(
                content: Data(headBytes), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [self] _ in end(client) })
            return
        }
        client.connection.send(
            content: Data(headBytes),
            completion: .contentProcessed { [self] error in
                if error != nil {
                    end(client)
                } else {
                    send(client, from: bytes.lowerBound, through: bytes.upperBound)
                }
            })
    }

    /// Sends the file's bytes a chunk at a time, each after the last is taken, all in the one
    /// final message: a final message sent while another is incomplete never goes. No idle timer
    /// runs while they go: a renderer that has buffered ahead, or is paused, takes nothing for
    /// as long as it likes, and closing on it cuts the track short (ADR 0125).
    private func send(_ client: Client, from offset: UInt64, through last: UInt64) {
        guard clients[ObjectIdentifier(client)] != nil, let file = client.file else { return }
        client.idle?.cancel()
        client.idle = nil
        let count = Int(min(UInt64(Self.chunkBytes), last - offset + 1))
        var chunk = [UInt8](repeating: 0, count: count)
        let read = chunk.withUnsafeMutableBytes {
            pread(file.fd, $0.baseAddress, count, off_t(offset))
        }
        guard read == count else {
            problem("couldn't read a file being served: it ended or failed at byte \(offset)")
            end(client)
            return
        }
        let next = offset + UInt64(count)
        let isLast = next > last
        client.connection.send(
            content: Data(chunk), contentContext: .finalMessage, isComplete: isLast,
            completion: .contentProcessed { [self] error in
                if error != nil || isLast {
                    end(client)
                } else {
                    send(client, from: next, through: last)
                }
            })
    }

    private func reply(_ client: Client, _ status: HTTPStatus, _ fields: [(String, String)] = []) {
        client.connection.send(
            content: Data(responseHead(status, fields: fields, length: 0)),
            contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [self] _ in end(client) })
    }

    private func responseHead(_ status: HTTPStatus, fields: [(String, String)], length: UInt64)
        -> [UInt8]
    {
        let lines =
            ["\(HTTPHead.version) \(status.rawValue) \(status.reason)"]
            + (fields + [("Content-Length", "\(length)"), ("Connection", "close")]).map {
                "\($0): \($1)"
            }
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Restarts the client's idle timer.
    private func touch(_ client: Client) {
        client.idle?.cancel()
        let timer = DispatchWorkItem { [self] in end(client) }
        client.idle = timer
        queue.asyncAfter(deadline: .now() + idleSeconds, execute: timer)
    }

    private func end(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.idle?.cancel()
        client.file = nil
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }

    /// How many connections are open, for tests.
    var openConnections: Int { queue.sync { clients.count } }
}

/// One connection's state, touched only on the server's queue.
private final class Client: @unchecked Sendable {
    let connection: NWConnection
    var received: [UInt8] = []
    var hasHead = false
    var idle: DispatchWorkItem?
    var file: OpenFile?

    init(_ connection: NWConnection) { self.connection = connection }
}

/// A regular file opened read-only without following a link, closed when released.
final class OpenFile {
    let fd: Int32
    let size: UInt64

    init(_ path: String) throws(LocalNetworkError) {
        // Nonblocking, so a FIFO put in a file's place can't hold the open.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw .system("open", errno: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw .system("fstat", errno: code)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw .failed("\(path) isn't a regular file")
        }
        guard fcntl(fd, F_SETFL, 0) == 0 else {
            let code = errno
            close(fd)
            throw .system("fcntl", errno: code)
        }
        self.fd = fd
        size = UInt64(info.st_size)
    }

    deinit { close(fd) }
}
