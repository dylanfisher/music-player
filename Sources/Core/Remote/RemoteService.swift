import Commands
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
    private let port: UInt16
    private let hub: RemoteEventHub
    private let advertiser: any BonjourAdvertising
    private let browser: any BonjourBrowsing
    private let problem: @Sendable (String) -> Void
    private let lock = NSLock()
    private var server: RemoteServer?
    private var generation = 0
    private var own: RemoteInstance?
    private var found: [RemoteInstance] = []
    private var subnets = LocalSubnets([])
    /// The interfaces the server listens on.
    private var running: [NetworkInterface] = []
    private var refused: Set<String> = []
    /// Set once, at the end of `init`, since its instance list reads this service.
    private var api: RemoteAPI?

    /// `state` says what's playing now, `run` runs a command as `Origin.remote`, and `page`
    /// is the web page's HTML.
    public init(
        identity: Identity, port: UInt16, devices: RemoteDeviceRegistry, page: [UInt8],
        state: @escaping @Sendable () async -> RemoteState,
        run: @escaping @Sendable (CommandID, String?) async -> ScriptReply,
        advertiser: any BonjourAdvertising, browser: any BonjourBrowsing,
        problem: @escaping @Sendable (String) -> Void,
        pairing: RemotePairing = RemotePairing(),
        sleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1e9))
        }
    ) {
        self.identity = identity
        self.port = port
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

    /// Starts on `interfaces`, or starts again on them, as when the Mac joins another network,
    /// keeping the code shown. Throws when no interface can listen on the port.
    public func start(on interfaces: [NetworkInterface]) async throws(LocalNetworkError) {
        let started = lock.withLock { () -> Int in
            generation += 1
            return generation
        }
        stopServing()
        guard let api = lock.withLock({ self.api }) else {
            preconditionFailure("the service's API is set in init")
        }
        let made = try await RemoteServer.start(
            on: interfaces, port: port,
            hostNames: [dotLocal(identity.host)],
            allowsOrigin: { [weak self] in self?.allows(origin: $0) ?? false },
            handler: { await api.handle($0) }, problem: problem)
        let addresses = interfaces.map(\.address).filter { !$0.isLinkLocal }
            .sorted { if case .v4 = $0, case .v6 = $1 { true } else { false } }
            .map(\.description)
        let instance = RemoteInstance(
            id: identity.id, name: identity.name, host: identity.host, addresses: addresses,
            port: made.port)
        let current = lock.withLock { () -> Bool in
            guard generation == started else { return false }
            server = made
            own = instance
            subnets = LocalSubnets(interfaces)
            running = interfaces
            return true
        }
        guard current else { return made.stop() }
        advertiser.start(instance.advert, problem: problem)
        browser.start(
            type: RemoteInstance.serviceType, found: { [weak self] in self?.update($0) },
            problem: problem)
    }

    /// Starts on `interfaces` unless it's running on just those already, as when the Mac's
    /// network changes in a way that leaves its addresses as they were.
    public func follow(_ interfaces: [NetworkInterface]) async throws(LocalNetworkError) {
        guard lock.withLock({ server == nil || running != interfaces }) else { return }
        try await start(on: interfaces)
    }

    /// Stops listening, advertising and browsing, closes every connection and ends the code.
    public func stop() {
        lock.withLock { generation += 1 }
        stopServing()
        pairing.clear()
    }

    private func stopServing() {
        let running = lock.withLock { () -> RemoteServer? in
            defer {
                server = nil
                own = nil
                found = []
                running = []
            }
            return server
        }
        running?.stop()
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

    private func update(_ adverts: [BonjourFound]) {
        let problems = lock.withLock { () -> [String] in
            var seen: Set<String> = []
            var next: [RemoteInstance] = []
            var bad: [String] = []
            for advert in adverts {
                switch RemoteInstance.parse(advert, subnets: subnets) {
                case .success(let instance):
                    guard instance.id != identity.id, seen.insert(instance.id).inserted else {
                        continue
                    }
                    next.append(instance)
                case .failure(let refusal):
                    // Once per name, so a stray advert isn't reported each time the set changes.
                    if refused.insert(advert.name).inserted {
                        bad.append(
                            "ignored the Bonjour advert \"\(advert.name)\": no \(refusal.missing)")
                    }
                }
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
