import Foundation
import LocalNetwork
import Log
import UPnP

private let logger = moduleLogger()

/// Receiver control: finds the one Denon receiver among the renderers discovery gives, or else
/// the address the owner configured when it's on a local subnet, keeps a connection to its control
/// port, and follows its status lines (ADR 0039). Nothing here runs until `start`, which the app
/// calls only when `receiver.enabled` is on.
@MainActor
public final class ReceiverControl {
    public enum Status: Equatable, Sendable {
        case stopped
        case searching
        case connecting(String)
        case connected(String)
        /// Why; a command from the owner searches and connects again, nothing else does.
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

    /// Most commands kept while a search runs, to send once it connects.
    static let pendingCap = 16
    /// How many updates from the connection wait for the main actor; past this the oldest are
    /// dropped, so a receiver flooding lines can't queue work without bound.
    static let updateBufferCap = 64

    public private(set) var state = ReceiverState()
    public private(set) var status = Status.stopped
    /// Called after `state` or `status` changes.
    public var changed: () -> Void = {}
    private let discover: Discover
    /// The configured address, preferred among Denons and used when discovery finds none.
    private let fallback: () -> LocalNetwork.IPAddress?
    private let interfaces: () throws -> [NetworkInterface]
    private let problem: (Problem) -> Void
    private let port: UInt16
    /// Where the receiver is and what it's called, while connected or connecting.
    private var receiver: (address: LocalNetwork.IPAddress, name: String)?
    private var connection: ReceiverConnection?
    private(set) var listening: Task<Void, Never>?
    private var searching: Task<Void, Never>?
    /// Commands the owner gave while a search ran, sent once it connects.
    private var pending: [ReceiverCommand] = []
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

    /// Whether receiver control runs, and with it the Mac's volume and mute keys drive the
    /// receiver (ADR 0093): when `receiver.enabled` is on, and while the app plays to a Denon
    /// receiver as a renderer, whose volume is the receiver's own and set only here (ADR 0041).
    /// Choosing that renderer already put the app on the network.
    public nonisolated static func isWanted(enabled: Bool, playingTo renderer: Renderer?) -> Bool {
        enabled || renderer?.isDenonReceiver == true
    }

    /// What to do for volume keys that are wanted: tap them with permission; without it, show
    /// the system's prompt once ever, and after that say once a launch how to grant it, so an
    /// owner who declined isn't asked again.
    public enum VolumeKeyAccess: Equatable, Sendable {
        case tap, prompt, explain, nothing
    }

    public nonisolated static let accessibilityHint =
        "The volume keys need Accessibility permission to control the receiver: System"
        + " Preferences › Security & Privacy › Privacy › Accessibility."

    public nonisolated static func volumeKeyAccess(
        permitted: Bool, promptedBefore: Bool, explainedThisLaunch: Bool
    ) -> VolumeKeyAccess {
        if permitted { return .tap }
        if !promptedBefore { return .prompt }
        return explainedThisLaunch ? .nothing : .explain
    }

    /// Receiver control as `receiver.enabled` asks: started when it's on and stopped and gone
    /// when it's off. `current` is the control running now; `make` makes one.
    public static func applying(
        enabled: Bool, to current: ReceiverControl?, make: () -> ReceiverControl
    ) -> ReceiverControl? {
        guard enabled else {
            current?.stop()
            return nil
        }
        let control = current ?? make()
        control.start()
        return control
    }

    /// Searches for the receiver and connects to it.
    public func start() {
        stop()
        search()
    }

    /// Ends the search and the connection, and forgets the receiver and its state.
    public func stop() {
        session += 1
        searching?.cancel()
        searching = nil
        endConnection()
        pending = []
        set(.stopped)
    }

    /// Sends `command`. With no connection, it searches again first, since the receiver may
    /// have moved; this and a setting change are the only things that search or connect.
    public func run(_ command: ReceiverCommand) {
        if let connection {
            switch connection.send(command.line) {
            case .queued: return
            case .full:
                problem(
                    .ignored(
                        "a command: \(ReceiverConnection.waitingCap) were already waiting to be"
                            + " sent"))
                return
            case .ended:
                // Its end is on the way; the command starts the search it would.
                endConnection()
            }
        }
        guard pending.count < Self.pendingCap else {
            problem(.ignored("a command: \(Self.pendingCap) were already waiting for the receiver"))
            return
        }
        pending.append(command)
        if searching == nil { search() }
    }

    private func search() {
        session += 1
        let session = session
        set(.searching)
        searching = Task {
            let outcome: RendererDiscovery.Outcome
            do {
                outcome = try await discover()
            } catch {
                guard session == self.session else { return }
                searching = nil
                useFallback(or: "the search failed: \(error)")
                return
            }
            guard session == self.session else { return }
            searching = nil
            found(outcome)
        }
    }

    /// Which of the renderers is the receiver.
    enum Choice: Equatable {
        case found(Renderer)
        case none
        /// More than one address answered; says which.
        case several(String)
    }

    /// The Denon among `renderers`. The owner's address picks among them; otherwise only
    /// receivers count, since a Denon Home or HEOS speaker answers too. A receiver can answer
    /// as more than one device, all at its one address.
    nonisolated static func receiver(
        among renderers: [Renderer], configured: LocalNetwork.IPAddress?
    ) -> Choice {
        let chosen =
            renderers.filter { $0.isDenon && $0.address == configured }.nilIfEmpty
            ?? renderers.filter(\.isDenonReceiver)
        let addresses = Set(chosen.map(\.address))
        guard let first = chosen.first else { return .none }
        guard addresses.count == 1 else {
            return .several(
                "\(addresses.count) Denon receivers answered: "
                    + chosen.map { "\($0.name) at \($0.address)" }.sorted().joined(separator: ", ")
                    + "; set receiver.address to the one to control")
        }
        return .found(first)
    }

    private func found(_ outcome: RendererDiscovery.Outcome) {
        for ignored in outcome.problems { problem(.ignored("\(ignored)")) }
        if outcome.moreProblems > 0 {
            problem(.ignored("\(outcome.moreProblems) more replies"))
        }
        let first: Renderer
        switch Self.receiver(among: outcome.renderers, configured: fallback()) {
        case .found(let renderer): first = renderer
        case .none:
            useFallback(or: "no Denon receiver answered on the local network")
            return
        case .several(let why):
            fail(why)
            return
        }
        if let why = first.formatsProblem {
            logger.notice("the receiver's formats weren't read: \(why)")
        }
        connect(to: first.address, name: first.name)
    }

    /// Connects to `receiver.address` when it's another device on a local subnet; otherwise
    /// reports `why` no receiver was found.
    private func useFallback(or why: String) {
        guard let address = fallback() else { return fail(why) }
        let up: [NetworkInterface]
        do {
            up = try interfaces()
        } catch {
            return fail("\(why), and the interfaces couldn't be listed: \(error)")
        }
        guard LocalSubnets(up).interface(forHost: address) != nil else {
            return fail(
                "\(why), and the receiver address \(address) isn't another device's address on"
                    + " a local subnet")
        }
        connect(to: address, name: "the receiver at \(address)")
    }

    private func connect(to address: LocalNetwork.IPAddress, name: String) {
        endConnection()
        receiver = (address, name)
        let (updates, continuation) = AsyncStream.makeStream(
            of: ReceiverConnection.Update.self,
            bufferingPolicy: .bufferingNewest(Self.updateBufferCap))
        let connection = ReceiverConnection(address: address, port: port) { update in
            continuation.yield(update)
            if case .ended = update { continuation.finish() }
        }
        self.connection = connection
        ignoredLines = 0
        set(.connecting(name))
        let session = session
        listening = Task {
            for await update in updates {
                guard session == self.session, connection === self.connection else { return }
                handle(update, from: connection)
            }
        }
        connection.start()
        for command in pending { connection.send(command.line) }
        pending = []
    }

    private func handle(_ update: ReceiverConnection.Update, from connection: ReceiverConnection) {
        switch update {
        case .connected:
            // Answers come first, so the model starts from the receiver's state.
            for query in statusQueries { connection.send(query) }
        case .line(let line, let text):
            if case .connecting(let name) = status { set(.connected(name)) }
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
            endConnection()
            fail("\(reason)")
        }
    }

    /// Closes the connection, if any, and forgets what it reported, so no check mark shows a
    /// state from before.
    private func endConnection() {
        connection?.stop()
        connection = nil
        listening?.cancel()
        listening = nil
        receiver = nil
        state = ReceiverState()
    }

    private func ignore(_ what: String) {
        ignoredLines += 1
        if ignoredLines <= Self.ignoredLineCap {
            problem(.ignored(what))
        } else if ignoredLines == Self.ignoredLineCap + 1 {
            problem(.ignored("more status lines; the rest aren't reported"))
        }
    }

    /// No receiver to talk to: the commands waiting for one are dropped with the report.
    private func fail(_ why: String) {
        pending = []
        set(.unreachable(why))
        problem(.unreachable(why))
    }

    private func set(_ status: Status) {
        self.status = status
        changed()
    }
}

extension Array {
    fileprivate var nilIfEmpty: Self? { isEmpty ? nil : self }
}
