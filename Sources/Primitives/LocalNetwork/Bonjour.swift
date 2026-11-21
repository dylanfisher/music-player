import Foundation
import Network
import dnssd

/// A service as Bonjour advertises it: its name, type, port and TXT record.
public struct BonjourAdvert: Equatable, Sendable {
    public var name: String
    /// `_music-player._tcp`.
    public var type: String
    public var port: UInt16
    public var txt: [String: String]

    public init(name: String, type: String, port: UInt16, txt: [String: String]) {
        self.name = name
        self.type = type
        self.port = port
        self.txt = txt
    }

    /// The TXT record's bytes: each `key=value` after its length, sorted by key. Nil when an
    /// entry is over the 255 bytes one may hold.
    var txtRecord: [UInt8]? {
        var bytes: [UInt8] = []
        for (key, value) in txt.sorted(by: { $0.key < $1.key }) {
            let entry = Array("\(key)=\(value)".utf8)
            guard entry.count <= 255 else { return nil }
            bytes.append(UInt8(entry.count))
            bytes += entry
        }
        return bytes
    }
}

/// A service another host advertises: its name and TXT record. Bonjour's own port and addresses
/// need a resolve per service, so what a caller needs of them goes in the TXT record.
public struct BonjourFound: Equatable, Sendable {
    public var name: String
    public var txt: [String: String]
}

/// Advertises one service until stopped. Injected, so no test advertises on the LAN.
public protocol BonjourAdvertising: Sendable {
    func start(_ advert: BonjourAdvert, problem: @escaping @Sendable (String) -> Void)
    func stop()
}

/// Browses for one type of service until stopped, calling `found` with every service seen now
/// each time the set changes. Injected, so no test browses the LAN.
public protocol BonjourBrowsing: Sendable {
    func start(
        type: String, found: @escaping @Sendable ([BonjourFound]) -> Void,
        problem: @escaping @Sendable (String) -> Void)
    func stop()
}

/// The system's advertiser, through dns_sd. Its reference is touched only on `queue`, where
/// dns_sd calls back too.
public final class DNSServiceAdvertiser: BonjourAdvertising, @unchecked Sendable {
    private let queue = DispatchQueue(label: "DNSServiceAdvertiser")
    private var reference: DNSServiceRef?
    private var report: Unmanaged<ProblemBox>?

    public init() {}

    public func start(_ advert: BonjourAdvert, problem: @escaping @Sendable (String) -> Void) {
        queue.sync {
            stopOnQueue()
            guard let txt = advert.txtRecord else {
                return problem("can't advertise \(advert.name): a TXT entry is over 255 bytes")
            }
            let box = Unmanaged.passRetained(ProblemBox(problem))
            var made: DNSServiceRef?
            let error = txt.withUnsafeBytes { record in
                DNSServiceRegister(
                    &made, 0, 0, advert.name, advert.type, nil, nil, advert.port.bigEndian,
                    UInt16(record.count), record.baseAddress,
                    { _, _, error, name, _, _, context in
                        guard error != kDNSServiceErr_NoError, let context else { return }
                        let box = Unmanaged<ProblemBox>.fromOpaque(context).takeUnretainedValue()
                        box.problem(
                            "Bonjour stopped advertising \(name.map { String(cString: $0) } ?? ""):"
                                + " error \(error)")
                    }, box.toOpaque())
            }
            guard error == kDNSServiceErr_NoError, let made else {
                box.release()
                return problem("can't advertise \(advert.name) over Bonjour: error \(error)")
            }
            DNSServiceSetDispatchQueue(made, queue)
            reference = made
            report = box
        }
    }

    public func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        if let reference { DNSServiceRefDeallocate(reference) }
        reference = nil
        report?.release()
        report = nil
    }
}

/// A problem callback held for a C callback's context.
private final class ProblemBox: Sendable {
    let problem: @Sendable (String) -> Void
    init(_ problem: @escaping @Sendable (String) -> Void) { self.problem = problem }
}

/// The system's browser, through `NWBrowser`. Its browser is touched only on `queue`, where
/// the browser's handlers run too.
public final class NetworkBrowser: BonjourBrowsing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "NetworkBrowser")
    private var browser: NWBrowser?

    public init() {}

    public func start(
        type: String, found: @escaping @Sendable ([BonjourFound]) -> Void,
        problem: @escaping @Sendable (String) -> Void
    ) {
        queue.sync {
            browser?.cancel()
            let made = NWBrowser(
                for: .bonjourWithTXTRecord(type: type, domain: nil), using: NWParameters())
            made.browseResultsChangedHandler = { results, _ in
                found(
                    results.compactMap { result in
                        guard case .service(let name, _, _, _) = result.endpoint else {
                            return nil
                        }
                        guard case .bonjour(let record) = result.metadata else {
                            return BonjourFound(name: name, txt: [:])
                        }
                        return BonjourFound(name: name, txt: record.dictionary)
                    })
            }
            made.stateUpdateHandler = { state in
                if case .failed(let error) = state { problem("Bonjour browsing failed: \(error)") }
            }
            made.start(queue: queue)
            browser = made
        }
    }

    public func stop() {
        queue.sync {
            browser?.cancel()
            browser = nil
        }
    }
}
