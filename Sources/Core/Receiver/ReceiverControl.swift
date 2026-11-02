import Foundation
import LocalNetwork
import Log
import UPnP

private let logger = moduleLogger()

/// Receiver control: finds the one Denon among the renderers discovery gives, or else the
/// address the owner configured when it's on a local subnet, keeps a connection to its control
/// port, and follows its status lines (ADR 0039). Nothing here runs until `start`, which the app
/// calls only when `receiver.enabled` is on.
@MainActor
public final class ReceiverControl {
    public enum Status: Equatable, Sendable {
        case stopped
        case searching
        case connecting(String)
        case connected(String)
        /// Why; a command from the owner tries the connection again, nothing else does.
        case unreachable(String)
    }

    /// What the owner should hear about, as status bar lines or log lines.
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        /// No receiver, or the connection to it ended.
        case unreachable(String)
        /// Discovery or a status line found something it ignored.
        case ignored(String)

        public var description: String {
            switch self {
            case .unreachable(let why):
                "the receiver is unreachable: \(why). \(ReceiverControl.unreachableHint)"
            case .ignored(let what): "receiver control ignored \(what)"
            }
        }
    }

    public typealias Discover = @Sendable () async throws -> RendererDiscovery.Outcome

    /// What the owner's own scripts say when the receiver doesn't answer.
    nonisolated static let unreachableHint =
        "Is it on the network, with Network Control set to Always On?"

    /// Most ignored status lines reported per connection; the rest are counted once.
    static let ignoredLineCap = 20

    public private(set) var state = ReceiverState()
    public private(set) var status = Status.stopped
    /// Called after `state` or `status` changes.
    public var changed: () -> Void = {}
    private let discover: Discover
    /// The configured address, used when discovery finds no receiver.
    private let fallback: () -> LocalNetwork.IPAddress?
    private let interfaces: () throws -> [NetworkInterface]
    private let problem: (Problem) -> Void
    private let port: UInt16
    /// Where the receiver is and what it's called, once found.
    private var receiver: (address: LocalNetwork.IPAddress, name: String)?
    private var connection: ReceiverConnection?
    private var listening: Task<Void, Never>?
    /// Bumped on each start and stop, so a search or a connection from before is dropped.
    private var session = 0
    private var ignoredLines = 0

    /// `fallback` is `receiver.address`; `interfaces` lists the interfaces that are up, which
    /// it must be on.
    public convenience init(
        discover: @escaping Discover, fallback: @escaping () -> LocalNetwork.IPAddress?,
        interfaces: @escaping () throws -> [NetworkInterface],
        problem: @escaping (Problem) -> Void
    ) {
        self.init(
            discover: discover, fallback: fallback, interfaces: interfaces, problem: problem,
            port: ReceiverConnection.port)
    }

    init(
        discover: @escaping Discover, fallback: @escaping () -> LocalNetwork.IPAddress?,
        interfaces: @escaping () throws -> [NetworkInterface],
        problem: @escaping (Problem) -> Void, port: UInt16
    ) {
        self.discover = discover
        self.fallback = fallback
        self.interfaces = interfaces
        self.problem = problem
        self.port = port
    }

    /// Searches for the receiver and connects to it.
    public func start() {
        stop()
        session += 1
        let session = session
        set(.searching)
        Task {
            let outcome: RendererDiscovery.Outcome
            do {
                outcome = try await discover()
            } catch {
                guard session == self.session else { return }
                useFallback(or: "the search failed: \(error)")
                return
            }
            guard session == self.session else { return }
            found(outcome)
        }
    }

    /// Closes the connection and forgets the receiver and its state.
    public func stop() {
        session += 1
        connection?.stop()
        connection = nil
        listening?.cancel()
        listening = nil
        receiver = nil
        state = ReceiverState()
        set(.stopped)
    }

    /// Whether commands can go to a receiver: one was found, connected or not.
    public var hasReceiver: Bool { receiver != nil }

    /// Sends `command`. When the connection has ended, this is the one thing that opens it
    /// again, since the owner asked.
    public func run(_ command: ReceiverCommand) {
        guard receiver != nil else {
            problem(.unreachable("no receiver was found"))
            return
        }
        if connection == nil { connect() }
        guard connection?.send(command.line) == true else {
            problem(
                .ignored(
                    "a command: \(ReceiverConnection.waitingCap) were already waiting to be sent"))
            return
        }
    }

    private func found(_ outcome: RendererDiscovery.Outcome) {
        for ignored in outcome.problems { problem(.ignored("\(ignored)")) }
        if outcome.moreProblems > 0 {
            problem(.ignored("\(outcome.moreProblems) more replies"))
        }
        let denons = outcome.renderers.filter { $0.manufacturer.lowercased().contains("denon") }
        // A receiver can answer as more than one device, all at its one address.
        let addresses = Set(denons.map(\.address))
        guard !addresses.isEmpty else {
            useFallback(or: "no Denon receiver answered on the local network")
            return
        }
        guard let first = denons.first, addresses.count == 1 else {
            unreachable(
                "\(addresses.count) Denon receivers answered, at "
                    + addresses.map(\.description).sorted().joined(separator: ", ")
                    + "; receiver control works with one")
            return
        }
        receiver = (first.address, first.name)
        if let why = first.formatsProblem {
            logger.notice("the receiver's formats weren't read: \(why)")
        }
        connect()
    }

    /// Connects to `receiver.address` when it's set and on a local subnet; otherwise reports
    /// `why` no receiver was found.
    private func useFallback(or why: String) {
        guard let address = fallback() else { return unreachable(why) }
        let up: [NetworkInterface]
        do {
            up = try interfaces()
        } catch {
            return unreachable("\(why), and the interfaces couldn't be listed: \(error)")
        }
        guard LocalSubnets(up).interface(holding: address) != nil else {
            return unreachable(
                "\(why), and the receiver address \(address) isn't on a local subnet")
        }
        receiver = (address, "the receiver at \(address)")
        connect()
    }

    private func connect() {
        guard let receiver else { return }
        let (updates, continuation) = AsyncStream.makeStream(of: ReceiverConnection.Update.self)
        let connection = ReceiverConnection(address: receiver.address, port: port) {
            continuation.yield($0)
        }
        self.connection = connection
        ignoredLines = 0
        set(.connecting(receiver.name))
        let session = session
        listening = Task {
            for await update in updates {
                guard session == self.session, connection === self.connection else { return }
                handle(update, from: connection)
            }
        }
        connection.start()
    }

    private func handle(_ update: ReceiverConnection.Update, from connection: ReceiverConnection) {
        switch update {
        case .connected:
            set(.connected(receiver?.name ?? ""))
            for query in statusQueries { connection.send(query) }
        case .line(let line, let text):
            switch line {
            case .event(let event):
                if event == .input(nil) { ignore("an input it has no name for: \(text)") }
                state.apply(event)
                // A number logs in the clear, so the owner can watch the volume follow.
                if case .volume(let volume) = event {
                    logger.info("receiver volume \(volume.decibels) dB")
                }
                changed()
            case .ignored:
                break
            case .unknownValue:
                ignore("a value out of range: \(text)")
            case .notText:
                ignore("a line that isn't printable ASCII")
            }
        case .ended(let reason):
            self.connection = nil
            listening = nil
            unreachable("\(reason)")
        }
    }

    private func ignore(_ what: String) {
        ignoredLines += 1
        if ignoredLines <= Self.ignoredLineCap {
            problem(.ignored(what))
        } else if ignoredLines == Self.ignoredLineCap + 1 {
            problem(.ignored("more status lines; the rest aren't reported"))
        }
    }

    private func unreachable(_ why: String) {
        set(.unreachable(why))
        problem(.unreachable(why))
    }

    private func set(_ status: Status) {
        self.status = status
        changed()
    }
}
