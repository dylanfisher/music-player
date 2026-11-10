import Foundation
import LocalNetwork
import Network

/// A TCP server on 127.0.0.1 that plays a device, or a client's far end, in network tests, so
/// no test reaches past loopback. Each connection goes to `handler` on a task of its own.
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let accepted = LoopbackAccepted()

    init(handler: @escaping @Sendable (LoopbackConnection) async -> Void) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = LoopbackOnce<Result<UInt16, any Error>>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.set(.success(listener.port?.rawValue ?? 0))
            case .failed(let error), .waiting(let error): ready.set(.failure(error))
            default: break
            }
        }
        let accepted = accepted
        listener.newConnectionHandler = { connection in
            let peer = LoopbackConnection(connection)
            accepted.add(peer)
            Task { await handler(peer) }
        }
        listener.start(queue: DispatchQueue(label: "LoopbackServer"))
        self.listener = listener
        port = try await ready.value(seconds: 5).get()
    }

    /// How many connections came.
    var connectionCount: Int { accepted.all.count }

    /// Stops listening and closes every connection it accepted.
    func stop() {
        listener.cancel()
        for connection in accepted.all { connection.close() }
    }

    /// A port on 127.0.0.1 nothing listens on, so a connection is refused: below 1024, where a
    /// test can't bind, and tcpmux, which macOS doesn't serve. A port another test freed could
    /// be taken again by a third test's server while this one connects.
    static let refusingPort: UInt16 = 1
}

private final class LoopbackAccepted: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [LoopbackConnection] = []

    func add(_ connection: LoopbackConnection) { lock.withLock { connections.append(connection) } }

    var all: [LoopbackConnection] { lock.withLock { connections } }
}

/// One end of a loopback TCP connection, as a test drives it.
final class LoopbackConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "LoopbackConnection")
    private let lock = NSLock()
    private var buffered: [UInt8] = []
    private var closedByPeer = false

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        receiveMore()
    }

    /// A client connection to `port` on 127.0.0.1, ready. Retries "address in use" as
    /// `LocalHTTPClient` does.
    static func connect(port: UInt16) async throws -> LoopbackConnection {
        var attempt = 1
        while true {
            do {
                return try await connectOnce(port: port)
            } catch NWError.posix(.EADDRINUSE) where attempt < LocalHTTPClient.addressInUseTries {
                attempt += 1
                try await Task.sleep(
                    nanoseconds: UInt64(LocalHTTPClient.addressInUseRetrySeconds * 1e9))
            }
        }
    }

    private static func connectOnce(port: UInt16) async throws -> LoopbackConnection {
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = LoopbackOnce<Result<Void, any Error>>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.set(.success(()))
            case .failed(let error), .waiting(let error): ready.set(.failure(error))
            default: break
            }
        }
        let made = LoopbackConnection(connection)
        do {
            try await ready.value(seconds: 5).get()
        } catch {
            made.close()
            throw error
        }
        return made
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [self] data, _, isComplete, error in
            lock.withLock {
                if let data { buffered += data }
                if isComplete || error != nil { closedByPeer = true }
            }
            if !(isComplete || error != nil) { receiveMore() }
        }
    }

    /// Waits up to `seconds` for `take` to say how many of the bytes so far it wants, then
    /// takes those. Fails with what it saw. A test that expects nothing to come passes its own
    /// `seconds`; the default only guards against a hang.
    func receive(seconds: Double = waitLimit, take: @escaping ([UInt8], Bool) -> Int?)
        async throws -> [UInt8]
    {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let taken: [UInt8]? = lock.withLock {
                guard let count = take(buffered, closedByPeer) else { return nil }
                defer { buffered.removeFirst(count) }
                return Array(buffered.prefix(count))
            }
            if let taken { return taken }
            guard Date() < deadline else {
                let (bytes, closed) = lock.withLock { (buffered, closedByPeer) }
                throw LoopbackTimeout(seen: String(decoding: bytes, as: UTF8.self), closed: closed)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Everything up to the other end's close.
    func receiveAll(seconds: Double = waitLimit) async throws -> [UInt8] {
        try await receive(seconds: seconds) { bytes, closed in closed ? bytes.count : nil }
    }

    /// Bytes up to and including the first `marker`; the rest stay buffered.
    func receive(through marker: [UInt8], seconds: Double = waitLimit) async throws -> [UInt8] {
        try await receive(seconds: seconds) { bytes, _ in
            bytes.firstRange(of: marker).map { $0.upperBound }
        }
    }

    /// Exactly `count` bytes.
    func receive(count: Int, seconds: Double = waitLimit) async throws -> [UInt8] {
        try await receive(seconds: seconds) { bytes, _ in bytes.count >= count ? count : nil }
    }

    /// Whether the other end has closed, after waiting up to `seconds` for it.
    func closes(within seconds: Double) async -> Bool {
        do {
            _ = try await receive(seconds: seconds) { _, closed in closed ? 0 : nil }
            return true
        } catch {
            return false
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        let sent = LoopbackOnce<Result<Void, any Error>>()
        connection.send(
            content: Data(bytes),
            completion: .contentProcessed { error in
                sent.set(error.map { .failure($0) } ?? .success(()))
            })
        try await sent.value(seconds: 5).get()
    }

    func send(_ text: String) async throws { try await send(Array(text.utf8)) }

    func close() { connection.cancel() }
}

struct LoopbackTimeout: Error, CustomStringConvertible {
    var seen: String
    var closed: Bool
    var description: String { "timed out having seen \(seen.debugDescription), closed: \(closed)" }
}

/// A value set once from a callback and awaited.
final class LoopbackOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func set(_ value: Value) {
        lock.withLock { if stored == nil { stored = value } }
    }

    func value(seconds: Double) async throws -> Value {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let stored = lock.withLock({ stored }) { return stored }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw LoopbackTimeout(seen: "", closed: false)
    }
}
