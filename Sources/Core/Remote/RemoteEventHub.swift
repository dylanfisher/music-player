import Foundation
import LocalNetwork

/// The event streams' source (ADR 0214): while any stream is open, it reads the state every
/// `intervalSeconds` and sends it to every stream when it's news, so at most four events a
/// second, and to a new stream at once. A comment line every `heartbeatSeconds` finds a stream
/// whose reader went away. Its subscribers are guarded by `lock`; streams are finished outside
/// it, since finishing calls back into it.
final class RemoteEventHub: @unchecked Sendable {
    static let intervalSeconds = 0.25
    static let heartbeatSeconds = 15.0
    /// Events a stream holds for a reader that's behind; older ones are dropped, since each
    /// event is the whole state.
    static let bufferedEvents = 4
    /// Streams one device may hold: one per Mac's page it has open, with room for a reload.
    static let streamsPerDevice = 4

    private struct Subscriber {
        let tokenHash: String
        let continuation: AsyncStream<[UInt8]>.Continuation
        var fresh = true
    }

    private let lock = NSLock()
    private let state: @Sendable () async -> RemoteState
    private let sleep: @Sendable (Double) async throws -> Void
    private let problem: @Sendable (String) -> Void
    private var subscribers: [UUID: Subscriber] = [:]
    private var loop: Task<Void, Never>?
    private var last: RemoteState?

    /// `sleep` waits that many seconds, injected so tests needn't.
    init(
        state: @escaping @Sendable () async -> RemoteState,
        sleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1e9))
        },
        problem: @escaping @Sendable (String) -> Void
    ) {
        self.state = state
        self.sleep = sleep
        self.problem = problem
    }

    /// A new stream for the device with `tokenHash`, as the server sends it; a 503 for a
    /// device holding `streamsPerDevice` already, so one device can't take every stream.
    func subscribe(tokenHash: String) -> RemoteResponse {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [UInt8].self, bufferingPolicy: .bufferingNewest(Self.bufferedEvents))
        let id = UUID()
        let taken = lock.withLock { () -> Bool in
            let held = subscribers.values.filter { $0.tokenHash == tokenHash }.count
            guard held < Self.streamsPerDevice else { return false }
            subscribers[id] = Subscriber(tokenHash: tokenHash, continuation: continuation)
            if loop == nil { loop = Task { [weak self] in await self?.run() } }
            return true
        }
        guard taken else {
            continuation.finish()
            problem("the web remote refused a device's stream: it has \(Self.streamsPerDevice)")
            return .reply(RemoteReply(.serviceUnavailable))
        }
        continuation.onTermination = { [weak self] _ in self?.remove([id]) }
        return .events(stream, stop: { [weak self] in self?.remove([id]) })
    }

    /// Closes the streams of the device with `tokenHash`, once it's forgotten.
    func drop(tokenHash: String) {
        remove(lock.withLock { subscribers.filter { $0.value.tokenHash == tokenHash }.map(\.key) })
    }

    /// Closes every stream, as stopping the remote does.
    func stopAll() { remove(lock.withLock { Array(subscribers.keys) }) }

    var streamCount: Int { lock.withLock { subscribers.count } }

    private func remove(_ ids: [UUID]) {
        let removed = lock.withLock { () -> [Subscriber] in
            let gone = ids.compactMap { subscribers.removeValue(forKey: $0) }
            if subscribers.isEmpty {
                loop?.cancel()
                loop = nil
                last = nil
            }
            return gone
        }
        for subscriber in removed { subscriber.continuation.finish() }
    }

    private func run() async {
        var sinceBeat = 0.0
        while !Task.isCancelled {
            let current = await state()
            let targets = lock.withLock { () -> [AsyncStream<[UInt8]>.Continuation] in
                let news = last.map { current.isNews(after: $0) } ?? true
                if news { last = current }
                let chosen = subscribers.filter { news || $0.value.fresh }
                for id in chosen.keys { subscribers[id]?.fresh = false }
                return chosen.map(\.value.continuation)
            }
            if !targets.isEmpty {
                do {
                    let event = try Array("data: ".utf8) + remoteJSON(current) + Array("\n\n".utf8)
                    for target in targets { target.yield(event) }
                } catch {
                    problem("the web remote couldn't encode the state: \(error)")
                }
            }
            sinceBeat += Self.intervalSeconds
            if sinceBeat >= Self.heartbeatSeconds {
                sinceBeat = 0
                let all = lock.withLock { subscribers.values.map(\.continuation) }
                for target in all { target.yield(Array(":\n\n".utf8)) }
            }
            do {
                try await sleep(Self.intervalSeconds)
            } catch {
                return
            }
        }
    }
}

/// A reply's JSON: one line, keys sorted, slashes as they are.
func remoteJSON(_ value: some Encodable) throws -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Array(try encoder.encode(value))
}
