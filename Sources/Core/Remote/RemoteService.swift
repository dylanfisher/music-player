import Commands
import DisplayText
import Foundation
import LocalNetwork
import Scripting
import Settings

/// The web remote while `remote.enabled` is on (ADR 0214): the server on every LAN interface,
/// this instance's Bonjour advert, and the browser that finds the others, whose origins are the
/// only ones CORS lets in. Its server, generation and instances are guarded by `lock`.
public final class RemoteService: @unchecked Sendable {
    /// Who this instance is: its random ID, the computer's name and its `.local` host name.
    public struct Identity: Sendable {
        public var id: String
        public var name: String
        public var host: String

        public init(id: String, name: String, host: String) {
            self.id = id
            self.name = name
            self.host = host
        }
    }

    /// A new instance ID: 128 random bits as 32 hex digits.
    public static func newInstanceID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in generator.next() as UInt64 }
            .map { String(String(repeating: "0", count: 16) + String($0, radix: 16)).suffix(16) }
            .joined()
    }

    /// Whether `id`, as the state file holds it, is one `newInstanceID` made.
    public static func isInstanceID(_ id: String) -> Bool { Remote.isInstanceID(id) }

    public let pairing: RemotePairing
    public let devices: RemoteDeviceRegistry
    private let identity: Identity
    private let hub: RemoteEventHub
    private let advertiser: any BonjourAdvertising
    private let browser: any BonjourBrowsing
    private let problem: @Sendable (String) -> Void
    private let lock = NSLock()
    private var server: RemoteServer?
    /// Servers stopped whose listeners may not have closed yet, which a start waits for.
    private var closing: [RemoteServer] = []
    /// Moves on at each `stop`, so a start asked for before it does nothing.
    private var generation = 0
    /// The last of the starts and restarts, each of which waits for the one before.
    private var tail: Task<Void, Never>?
    private var own: RemoteInstance?
    private var found: [RemoteInstance] = []
    private var subnets = LocalSubnets([])
    /// The interfaces and port the server listens on; empty interfaces while it's stopped, or
    /// once a listener was lost, so the next `follow` starts it again.
    private var running: (interfaces: [NetworkInterface], port: UInt16) = ([], 0)
    /// The interfaces and port asked for last, which a lost listener starts again on.
    private var wanted: (interfaces: [NetworkInterface], port: UInt16)?
    /// Counts the servers started, so a loss from one that isn't `active` is ignored.
    private var serials = 0
    /// The serial of the server started last, nil once stopped.
    private var active: Int?
    /// Whether a restart after a loss is waiting out its delay, which folds in further losses.
    private var restarting = false
    /// Lost listeners since one stayed ready for `steadySeconds`; the next delay doubles per one.
    private var losses = 0
    /// When the server last became ready, on `now`'s clock.
    private var readyAt: Double?
    private let restartSleep: @Sendable (Double) async throws -> Void
    private let now: @Sendable () -> Double
    /// What was reported of adverts this session, so each is said once.
    private var refused: Set<String> = []
    /// Set once, at the end of `init`, since its instance list reads this service.
    private var api: RemoteAPI?

    /// Adverts reported in a session, past which the rest go unsaid.
    static let refusedCap = 64
    /// Characters of an advert's name kept: the name a Mac gives itself is far shorter.
    static let nameCharacters = 256
    /// The wait before the first restart after a lost listener, doubled for each further one.
    static let restartSeconds = 1.0
    /// The longest wait before a restart.
    static let restartCapSeconds = 30.0
    /// How long a listener stays ready before a loss counts as a first one again.
    static let steadySeconds = 60.0

    /// `state` says what's playing now, `run` runs a command as `Origin.remote`, and `page`
    /// is the web page's HTML.
    public init(
        identity: Identity, devices: RemoteDeviceRegistry, page: [UInt8],
        state: @escaping @Sendable () async -> RemoteState,
        run: @escaping @Sendable (CommandID, String?) async -> ScriptReply,
        advertiser: any BonjourAdvertising, browser: any BonjourBrowsing,
        problem: @escaping @Sendable (String) -> Void,
        pairing: RemotePairing = RemotePairing(),
        sleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1e9))
        },
        restartSleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1e9))
        },
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.restartSleep = restartSleep
        self.now = now
        self.identity = identity
        self.devices = devices
        self.pairing = pairing
        self.advertiser = advertiser
        self.browser = browser
        self.problem = problem
        let hub = RemoteEventHub(state: state, sleep: sleep, problem: problem)
        self.hub = hub
        devices.forgotten = { [weak hub] in hub?.drop(tokenHash: $0) }
        devices.reportSaveFailure = { problem("couldn't save when a device was last seen: \($0)") }
        api = RemoteAPI(
            instanceID: identity.id, name: identity.name, page: page, pairing: pairing,
            devices: devices, hub: hub, state: state, run: run,
            instances: { [weak self] in self?.instances ?? [] })
    }

    /// Starts on `interfaces` at `port`, or again when either changed or a listener was lost,
    /// keeping the code shown. Calls run one at a time, in the order made, and one made before
    /// a `stop` does nothing, so two at once or a quick off and on never leave two servers or
    /// none. Throws when no interface can listen on the port.
    public func follow(_ interfaces: [NetworkInterface], port: UInt16)
        async throws(LocalNetworkError)
    {
        try await followTask(interfaces, port: port).value.get()
    }

    /// `follow`'s work, queued now: its call is ordered before any `stop` made after it.
    func followTask(_ interfaces: [NetworkInterface], port: UInt16)
        -> Task<Result<Void, LocalNetworkError>, Never>
    {
        let asked = lock.withLock { () -> Int in
            wanted = (interfaces, port)
            return generation
        }
        return serially { [self] in
            let due = lock.withLock {
                generation == asked
                    && (server == nil || running.interfaces != interfaces || running.port != port)
            }
            guard due else { return .success(()) }
            do throws(LocalNetworkError) {
                try await start(on: interfaces, port: port, generation: asked)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
    }

    /// Queues `work` after every start before it.
    private func serially(
        _ work: @escaping @Sendable () async -> Result<Void, LocalNetworkError>
    ) -> Task<Result<Void, LocalNetworkError>, Never> {
        let task = lock.withLock { () -> Task<Result<Void, LocalNetworkError>, Never> in
            let previous = tail
            let made = Task {
                await previous?.value
                return await work()
            }
            tail = Task { _ = await made.value }
            return made
        }
        return task
    }

    private func start(on interfaces: [NetworkInterface], port: UInt16, generation asked: Int)
        async throws(LocalNetworkError)
    {
        stopServing()
        for stopped in lock.withLock({ () -> [RemoteServer] in
            defer { closing = [] }
            return closing
        }) {
            await stopped.closed()
        }
        guard let api = lock.withLock({ self.api }) else {
            preconditionFailure("the service's API is set in init")
        }
        let serial = lock.withLock { () -> Int in
            serials += 1
            active = serials
            return serials
        }
        let made = try await RemoteServer.start(
            on: interfaces, port: port, hostNames: [dotLocal(identity.host)],
            allowsOrigin: { [weak self] in self?.allows(origin: $0) ?? false },
            handler: { await api.handle($0) }, problem: problem,
            lost: { [weak self] in self?.listenerLost(from: serial) })
        let addresses = interfaces.map(\.address).filter { !$0.isLinkLocal }
            .sorted { if case .v4 = $0, case .v6 = $1 { true } else { false } }
            .map(\.description)
        let instance = RemoteInstance(
            id: identity.id, name: identity.name, host: identity.host, addresses: addresses,
            port: made.port)
        let current = lock.withLock { () -> Bool in
            // A stop while it bound: this server was never wanted.
            guard generation == asked else { return false }
            server = made
            own = instance
            subnets = LocalSubnets(interfaces)
            running = (interfaces, port)
            readyAt = now()
            return true
        }
        guard current else {
            // Closed before the start returns, so nothing listens once a stop's start is done.
            made.stop()
            await made.closed()
            return
        }
        advertiser.start(instance.advert, problem: problem)
        browser.start(
            type: RemoteInstance.serviceType, found: { [weak self] in self?.update($0) },
            problem: problem)
    }

    /// A listener of the server `serial` failed after it was ready: starts again on what was
    /// asked for last, after a wait that doubles with each loss in a row, up to
    /// `restartCapSeconds`. A loss from a server that isn't the current one, or while a restart
    /// is waiting, is ignored, so several failing interfaces make one restart.
    func listenerLost(from serial: Int) {
        let delay = lock.withLock { () -> Double? in
            guard active == serial, !restarting, wanted != nil else { return nil }
            restarting = true
            running.interfaces = []
            if let readyAt, now() - readyAt >= Self.steadySeconds { losses = 0 }
            defer { losses += 1 }
            return min(
                Self.restartSeconds * Double(sign: .plus, exponent: losses, significand: 1),
                Self.restartCapSeconds)
        }
        guard let delay else { return }
        Task { [weak self] in
            do {
                try await self?.restartSleep(delay)
            } catch {
                self?.problem("the web remote's restart was cancelled: \(error)")
            }
            guard let self else { return }
            let again = lock.withLock { () -> (interfaces: [NetworkInterface], port: UInt16)? in
                restarting = false
                return wanted
            }
            guard let again else { return }
            do throws(LocalNetworkError) {
                try await follow(again.interfaces, port: again.port)
            } catch {
                problem("the web remote can't listen again: \(error)")
            }
        }
    }

    /// Stops listening, advertising and browsing, closes every connection, a server still
    /// binding included, and ends the code.
    public func stop() {
        lock.withLock {
            generation += 1
            wanted = nil
        }
        stopServing()
        pairing.clear()
    }

    private func stopServing() {
        let current = lock.withLock { () -> RemoteServer? in
            let stopped = server
            active = nil
            server = nil
            own = nil
            found = []
            running = ([], 0)
            refused = []
            if let stopped { closing.append(stopped) }
            return stopped
        }
        current?.stop()
        hub.stopAll()
        advertiser.stop()
        browser.stop()
    }

    /// This instance, then every other one found, each once.
    var instances: [RemoteInstance] {
        lock.withLock { (own.map { [$0] } ?? []) + found }
    }

    /// The port the server listens on, nil while it's stopped.
    var listeningPort: UInt16? { lock.withLock { own?.port } }

    /// The server, for tests that fail its listeners.
    var currentServer: RemoteServer? { lock.withLock { server } }

    /// The serial of the current server, for tests that lose a listener of an old one.
    var currentSerial: Int? { lock.withLock { active } }

    /// Where a phone opens the page, nil while it's stopped.
    public var links: RemoteLinks? {
        lock.withLock {
            own.map { own in
                RemoteLinks(
                    local: own.origin(own.localName),
                    lan: own.addresses.first.flatMap(IPAddress.init).flatMap { address in
                        guard case .v4 = address else { return nil }
                        return own.origin(address.urlHost)
                    })
            }
        }
    }

    private func allows(origin: String) -> Bool {
        lock.withLock { found.contains { $0.origins.contains(origin) } }
    }

    /// Takes the adverts the browser sees now. One whose TXT record isn't an instance's is
    /// left out, as are all of those that claim one ID with different addresses, since a page
    /// keys its tokens by ID; each is reported once a session, up to `refusedCap`.
    private func update(_ adverts: [BonjourFound]) {
        let problems = lock.withLock { () -> [String] in
            var byID: [String: [RemoteInstance]] = [:]
            var bad: [String] = []
            func report(_ key: String, _ line: String) {
                guard refused.count < Self.refusedCap else { return }
                guard refused.insert(key).inserted else { return }
                bad.append(line)
                if refused.count == Self.refusedCap {
                    bad.append("the web remote logs no more Bonjour adverts until it stops")
                }
            }
            for advert in adverts {
                let name = String(terminalSafe(advert.name).prefix(Self.nameCharacters))
                switch RemoteInstance.parse(advert, subnets: subnets) {
                case .success(var instance):
                    guard instance.id != identity.id else { continue }
                    instance.name = name
                    byID[instance.id, default: []].append(instance)
                case .failure(let refusal):
                    report(
                        "name:" + name,
                        "ignored the Bonjour advert \"\(name)\": no \(refusal.missing)")
                }
            }
            var next: [RemoteInstance] = []
            for (id, claims) in byID {
                guard Set(claims.map { Set($0.addresses) }).count == 1 else {
                    report(
                        "id:" + id,
                        "ignored \(claims.count) Bonjour adverts that claim one ID with different"
                            + " addresses: "
                            + claims.map { "\"\($0.name)\"" }.joined(separator: ", "))
                    continue
                }
                next.append(claims[0])
            }
            found = next.sorted { $0.name < $1.name }
            return bad
        }
        for line in problems { problem(line) }
    }
}

/// Where a phone opens the page: by the Mac's `.local` name, and by its LAN address for when
/// that name doesn't resolve.
public struct RemoteLinks: Equatable, Sendable {
    public var local: String
    /// Nil when the Mac has no IPv4 address.
    public var lan: String?

    /// The link the QR code holds, which pairs as the page opens.
    public func pairing(_ code: String) -> String { local + "/#pair=" + code }
}
