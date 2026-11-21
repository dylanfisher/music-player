import Foundation
import Network

/// The web remote's server (ADR 0214): it answers any device on a local subnet, where
/// `HTTPServer` answers one renderer, and hands each request that passes `RemoteRules` to a
/// handler, which checks its token. It listens on each interface's address, on one port, and
/// takes connections only from that interface's subnet. A request's head and body must be whole
/// within `headSeconds` of its first byte, and a kept-alive connection closes after
/// `idleSeconds` with no request. At most `connectionCap` connections at once, of which
/// `eventStreamCap` may be event streams.
///
/// Its state is touched only on `queue`, where the listeners' and connections' handlers run.
public final class RemoteServer: @unchecked Sendable {
    public typealias Handler = @Sendable (RemoteRequest) async -> RemoteResponse

    static var connectionCap: Int { 32 }
    /// A phone holds one stream per Mac; the rest of the connections are left for requests.
    static var eventStreamCap: Int { 24 }
    static var headSeconds: Double { 10 }
    static var idleSeconds: Double { 30 }
    static var listenSeconds: Double { 5 }
    /// Events sent and not yet taken by a stream's client, past which it's too slow and closed.
    static var unsentEventCap: Int { 16 }
    /// A smaller body goes as it is: gzip's header and trailer cost more than they save.
    static var gzipMinimumBytes: Int { 512 }
    /// Refused connections logged in a server's session, so a LAN scanner can't flood the log;
    /// the rest are counted, and said as one line when it stops.
    static var refusalLogCap: Int { 10 }

    private let queue = DispatchQueue(label: "RemoteServer")
    private var listeners: [(listener: NWListener, interface: NetworkInterface)] = []
    private var rules = RemoteRules(authorities: [], allowsOrigin: { _ in false })
    private let handler: Handler
    private let problem: @Sendable (String) -> Void
    private let headSeconds: Double
    private let idleSeconds: Double
    private var clients: [ObjectIdentifier: RemoteClient] = [:]
    private var boundPort: UInt16 = 0
    private let lost: @Sendable () -> Void
    private var refusals = 0
    /// Listeners made and not yet cancelled, so a new server on the port waits for them.
    private var unclosed = 0

    /// Starts listening on every one of `interfaces` at `port`, reachable by their addresses
    /// and by each of `hostNames` ("studio.local"). `allowsOrigin` says whether a page from
    /// another origin, lowercased, may call it. Throws when no interface could listen; one that
    /// can't while others can is told to `problem`, which hears the first refused connections
    /// too. `lost` is called when a listener that was ready fails, as when its address goes.
    public static func start(
        on interfaces: [NetworkInterface], port: UInt16, hostNames: [String],
        allowsOrigin: @escaping @Sendable (String) -> Bool, handler: @escaping Handler,
        problem: @escaping @Sendable (String) -> Void, lost: @escaping @Sendable () -> Void
    ) async throws(LocalNetworkError) -> RemoteServer {
        try await start(
            on: interfaces, port: port, hostNames: hostNames, allowsOrigin: allowsOrigin,
            handler: handler, problem: problem, lost: lost, headSeconds: headSeconds,
            idleSeconds: idleSeconds)
    }

    static func start(
        on interfaces: [NetworkInterface], port: UInt16, hostNames: [String],
        allowsOrigin: @escaping @Sendable (String) -> Bool, handler: @escaping Handler,
        problem: @escaping @Sendable (String) -> Void, lost: @escaping @Sendable () -> Void,
        headSeconds: Double, idleSeconds: Double
    ) async throws(LocalNetworkError) -> RemoteServer {
        let server = RemoteServer(
            handler: handler, problem: problem, lost: lost, headSeconds: headSeconds,
            idleSeconds: idleSeconds)
        var failures: [String] = []
        var authorities: [String] = []
        for interface in interfaces {
            do throws(LocalNetworkError) {
                let bound = try await server.listen(on: interface, port: port)
                authorities.append("\(interface.address.urlHost):\(bound)")
            } catch {
                failures.append("\(interface): \(error)")
            }
        }
        guard !authorities.isEmpty else {
            server.stop()
            throw .failed(
                "the web remote can't listen on port \(port): "
                    + (failures.isEmpty ? "no interfaces" : failures.joined(separator: "; ")))
        }
        for failure in failures { problem("the web remote can't listen on \(failure)") }
        let port = server.port
        authorities += hostNames.map { "\($0):\(port)" }
        let rules = RemoteRules(authorities: authorities, allowsOrigin: allowsOrigin)
        server.queue.sync { server.rules = rules }
        return server
    }

    private init(
        handler: @escaping Handler, problem: @escaping @Sendable (String) -> Void,
        lost: @escaping @Sendable () -> Void, headSeconds: Double, idleSeconds: Double
    ) {
        self.handler = handler
        self.problem = problem
        self.lost = lost
        self.headSeconds = headSeconds
        self.idleSeconds = idleSeconds
    }

    /// Starts one listener and waits for it to be ready, returning the port it has.
    private func listen(on interface: NetworkInterface, port: UInt16)
        async throws(LocalNetworkError) -> UInt16
    {
        let parameters = directTCP()
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: interface.address.endpointHost, port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .failed("\(error)")
        }
        queue.sync { unclosed += 1 }
        let waiting = ListenWait()
        let outcome = await withCheckedContinuation { continuation in
            queue.sync { waiting.continuation = continuation }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard let bound = listener.port?.rawValue else {
                        listener.cancel()
                        return waiting.end(.failure(.failed("no port")))
                    }
                    listeners.append((listener, interface))
                    if boundPort == 0 { boundPort = bound }
                    waiting.end(.success(bound))
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    guard waiting.continuation != nil else {
                        return loseListener(listener, reason: "\(error)")
                    }
                    waiting.end(.failure(.failed("\(error)")))
                case .cancelled:
                    unclosed -= 1
                    waiting.end(.failure(.cancelled))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in accept(connection, interface) }
            listener.start(queue: queue)
            // Without a bound, a listener that never reports a state leaves the caller waiting.
            queue.asyncAfter(deadline: .now() + Self.listenSeconds) {
                guard waiting.continuation != nil else { return }
                listener.cancel()
                waiting.end(.failure(.timedOut))
            }
        }
        return try outcome.get()
    }

    /// Drops a listener that failed after it was ready, says so, and tells `lost`, which
    /// starts the server again.
    private func loseListener(_ listener: NWListener, reason: String) {
        guard let index = listeners.firstIndex(where: { $0.listener === listener }) else { return }
        let interface = listeners.remove(at: index).interface
        listener.newConnectionHandler = nil
        problem("the web remote stopped listening on \(interface): \(reason)")
        lost()
    }

    /// Fails the first listener as the system would, for tests.
    func loseFirstListener() {
        queue.sync {
            guard let first = listeners.first?.listener else { return }
            first.cancel()
            loseListener(first, reason: "a test failed it")
        }
    }

    /// Logs a refused connection while under `refusalLogCap` this session, and counts the rest.
    private func refuse(_ message: String) {
        refusals += 1
        if refusals <= Self.refusalLogCap { problem(message) }
        if refusals == Self.refusalLogCap {
            problem("the web remote logs no more refused connections until it stops")
        }
    }

    /// Waits, up to `listenSeconds`, until every listener has closed after `stop`, so a server
    /// started next on the same port can bind it.
    public func closed() async {
        for _ in 0..<Int(Self.listenSeconds * 100) {
            if queue.sync(execute: { unclosed }) <= 0 { return }
            try? await Task.sleep(nanoseconds: 10_000_000)  // A cancelled wait just ends it.
        }
        problem("the web remote's listeners hadn't closed within \(Self.listenSeconds) s")
    }

    /// The port the first listener has: `port` as asked, or the one the system picked for 0.
    public var port: UInt16 { queue.sync { boundPort } }

    /// Stops listening and closes every connection, event streams included.
    public func stop() {
        queue.sync {
            for (listener, _) in listeners {
                listener.newConnectionHandler = nil
                listener.cancel()
            }
            listeners = []
            for client in clients.values { end(client) }
            if refusals > Self.refusalLogCap {
                problem("the web remote refused \(refusals - Self.refusalLogCap) more connections")
            }
            refusals = 0
        }
    }

    private func accept(_ connection: NWConnection, _ interface: NetworkInterface) {
        guard let peer = IPAddress(peerOf: connection), interface.holds(peer) else {
            refuse("the web remote refused \(connection.endpoint), off \(interface)")
            connection.cancel()
            return
        }
        guard clients.count < Self.connectionCap else {
            refuse("the web remote refused \(peer): \(Self.connectionCap) connections are open")
            connection.cancel()
            return
        }
        let client = RemoteClient(connection, peer: peer)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: end(client)
            default: break
            }
        }
        connection.start(queue: queue)
        client.reading = true
        wait(client, headSeconds)
        receive(client)
    }

    private func receive(_ client: RemoteClient) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [self] data, _, isComplete, error in
            guard clients[ObjectIdentifier(client)] != nil else { return }
            if let data { client.received += data }
            if error != nil { return end(client) }
            // A stream's client has nothing more to send; whatever it sends is dropped.
            if client.streaming { client.received = [] }
            // Past a whole request's most, the client is sending ahead of its replies; while a
            // reply is pending, a second one can't go before it, so it just closes.
            if client.received.count > RemoteRules.headBytes + RemoteRules.bodyBytes {
                guard !client.busy else { return end(client) }
                return reply(client, RemoteReply(.payloadTooLarge), close: true)
            }
            if isComplete { client.peerClosed = true }
            if !client.busy { process(client) }
            if isComplete {
                // A stream ends with its reader; a reply still being made goes first.
                if client.streaming || !client.busy { end(client) }
            } else {
                receive(client)
            }
        }
    }

    /// Answers the request at the start of what's been received, once it's whole.
    private func process(_ client: RemoteClient) {
        guard !client.received.isEmpty else { return }
        if !client.reading {
            client.reading = true
            wait(client, headSeconds)
        }
        switch HTTPHead.parse(client.received[...], cap: RemoteRules.headBytes) {
        case .incomplete: return
        case .tooLarge: reply(client, RemoteReply(.headersTooLarge), close: true)
        case .malformed: reply(client, RemoteReply(.badRequest), close: true)
        case .head(let head, let length):
            let close = closes(head)
            switch rules.route(head) {
            case .refuse(let status):
                reply(client, RemoteReply(status), close: true)
            case .preflight(let origin):
                client.received.removeFirst(length)
                reply(
                    client,
                    RemoteReply(
                        .noContent,
                        fields: Self.preflightFields + cors(origin) + [("Vary", "Origin")]),
                    close: close)
            case .request(let bodyLength, let origin):
                guard client.received.count >= length + bodyLength else { return }
                let body = Array(client.received[length..<(length + bodyLength)])
                client.received.removeFirst(length + bodyLength)
                client.reading = false
                client.timer?.cancel()
                client.busy = true
                let request = RemoteRequest(head: head, body: body, peer: client.peer)
                let gzips = head.value("accept-encoding").map(acceptsGzip) ?? false
                Task { [self, handler] in
                    let response = await handler(request)
                    queue.async { [self] in
                        respond(client, response, origin: origin, gzips: gzips, close: close)
                    }
                }
            }
        }
    }

    private static let preflightFields = [
        ("Access-Control-Allow-Methods", "GET, POST"),
        ("Access-Control-Allow-Headers", "Authorization, Content-Type"),
        ("Access-Control-Max-Age", "600"),
    ]

    private func cors(_ origin: String?) -> [(String, String)] {
        guard let origin else { return [] }
        return [("Access-Control-Allow-Origin", origin)]
    }

    /// HTTP/1.0, or `Connection: close`, ends the connection after its reply.
    private func closes(_ head: HTTPHead) -> Bool {
        let tokens = head.values("connection").flatMap { $0.lowercased().split(separator: ",") }
            .map { $0.trimmingCharacters(in: [" ", "\t"]) }
        return head.start[2] != HTTPHead.version || tokens.contains(HTTPWord.close)
    }

    private func respond(
        _ client: RemoteClient, _ response: RemoteResponse, origin: String?, gzips: Bool,
        close: Bool
    ) {
        guard clients[ObjectIdentifier(client)] != nil else {
            if case .events(_, let stop) = response { stop() }
            return
        }
        switch response {
        case .reply(var reply):
            // Always, so a reply without the CORS field isn't cached for a page that needs it.
            reply.fields += cors(origin) + [("Vary", "Origin")]
            if gzips, reply.contentType != nil, reply.body.count >= Self.gzipMinimumBytes {
                reply.body = gzip(reply.body)
                reply.fields += [("Content-Encoding", gzipCoding), ("Vary", "Accept-Encoding")]
            }
            self.reply(client, reply, close: close || client.peerClosed)
        case .events(let stream, let stop):
            let streams = clients.values.filter(\.streaming).count
            guard streams < Self.eventStreamCap else {
                stop()
                refuse("the web remote refused an event stream: \(streams) are open")
                return reply(client, RemoteReply(.serviceUnavailable), close: true)
            }
            client.streaming = true
            client.stopEvents = stop
            let fields =
                [
                    (HTTPWord.contentType, "text/event-stream"),
                    (HTTPWord.cacheControl, HTTPWord.noStore),
                    (HTTPWord.connection, HTTPWord.close),
                ] + cors(origin) + [("Vary", "Origin")]
            client.connection.send(
                content: Data(head(.ok, fields)),
                completion: .contentProcessed { [self] error in
                    if error != nil { end(client) }
                })
            client.events = Task { [self] in
                for await chunk in stream {
                    queue.async { [self] in send(client, event: chunk) }
                }
                queue.async { [self] in end(client) }
            }
        }
    }

    private func send(_ client: RemoteClient, event: [UInt8]) {
        guard clients[ObjectIdentifier(client)] != nil else { return }
        guard client.unsent < Self.unsentEventCap else {
            problem("the web remote closed an event stream to \(client.peer) that wasn't read")
            return end(client)
        }
        client.unsent += 1
        client.connection.send(
            content: Data(event),
            completion: .contentProcessed { [self] error in
                client.unsent -= 1
                if error != nil { end(client) }
            })
    }

    private func reply(_ client: RemoteClient, _ reply: RemoteReply, close: Bool) {
        var fields = reply.fields
        if let type = reply.contentType { fields.insert((HTTPWord.contentType, type), at: 0) }
        // A 204 has no body, so no length either.
        if reply.status != .noContent {
            fields.append((HTTPWord.contentLength, "\(reply.body.count)"))
        }
        fields.append((HTTPWord.connection, close ? HTTPWord.close : "keep-alive"))
        client.busy = true
        client.timer?.cancel()
        client.connection.send(
            content: Data(head(reply.status, fields) + reply.body),
            contentContext: close ? .finalMessage : .defaultMessage, isComplete: true,
            completion: .contentProcessed { [self] error in
                guard clients[ObjectIdentifier(client)] != nil else { return }
                if error != nil || close || client.peerClosed { return end(client) }
                client.busy = false
                client.reading = false
                wait(client, idleSeconds)
                process(client)
            })
    }

    private func head(_ status: HTTPStatus, _ fields: [(String, String)]) -> [UInt8] {
        let lines =
            ["\(HTTPHead.version) \(status.rawValue) \(status.reason)"]
            + fields.map { "\($0): \($1)" }
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Closes the client after `seconds` unless something restarts or cancels the timer.
    private func wait(_ client: RemoteClient, _ seconds: Double) {
        client.timer?.cancel()
        let timer = DispatchWorkItem { [self] in end(client) }
        client.timer = timer
        queue.asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    private func end(_ client: RemoteClient) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.timer?.cancel()
        client.events?.cancel()
        client.stopEvents?()
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }

    /// How many connections are open, and how many are event streams, for tests.
    var openConnections: (all: Int, streams: Int) {
        queue.sync { (clients.count, clients.values.filter(\.streaming).count) }
    }
}

/// One connection's state, touched only on the server's queue.
private final class RemoteClient: @unchecked Sendable {
    let connection: NWConnection
    let peer: IPAddress
    var received: [UInt8] = []
    var timer: DispatchWorkItem?
    /// A request's first byte came, and its head and body are being read, against the clock.
    var reading = false
    /// A request is with the handler, or its reply is being sent.
    var busy = false
    var streaming = false
    /// The client closed its side; its last reply still goes.
    var peerClosed = false
    var events: Task<Void, Never>?
    var stopEvents: (@Sendable () -> Void)?
    var unsent = 0

    init(_ connection: NWConnection, peer: IPAddress) {
        self.connection = connection
        self.peer = peer
    }
}

/// A listener's wait to be ready, touched only on the server's queue, so it ends once.
private final class ListenWait: @unchecked Sendable {
    var continuation: CheckedContinuation<Result<UInt16, LocalNetworkError>, Never>?

    func end(_ outcome: Result<UInt16, LocalNetworkError>) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
