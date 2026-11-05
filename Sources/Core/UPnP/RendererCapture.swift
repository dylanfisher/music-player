import Foundation
import LocalNetwork

/// A file a capture writes: bytes exactly as a device sent them.
public struct CaptureFile: Equatable, Sendable {
    public let name: String
    public let bytes: [UInt8]

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }

    /// Writes `files` into `folder`, made if it's missing. One file that can't be written is
    /// reported and the rest are still written; only a folder that can't be made throws.
    public static func write(_ files: [CaptureFile], to folder: URL) throws -> (
        written: [String], failures: [String]
    ) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [String] = []
        var failures: [String] = []
        for file in files {
            do {
                try Data(file.bytes).write(
                    to: folder.appendingPathComponent(file.name, isDirectory: false),
                    options: .atomic)
                written.append(file.name)
            } catch {
                failures.append("\(file.name): couldn't be written: \(error)")
            }
        }
        return (written, failures)
    }
}

/// What the owner's receiver says about itself, saved raw for the next phase to start from
/// (ADR 0039): the SSDP replies, then each renderer's description, `GetProtocolInfo` reply and
/// service descriptions. It sends what discovery sends and no more, under the same checks;
/// parsing is only to find the next address to fetch, so a document that won't parse is still
/// saved.
public enum RendererCapture {
    /// How long the search listens, longer than discovery's, since a slow device is worth waiting
    /// for here.
    public static let searchSeconds = 5.0
    /// The services whose descriptions are saved.
    static let services = ["AVTransport", "RenderingControl", "ConnectionManager"]

    public struct Result: Sendable {
        public var files: [CaptureFile] = []
        public var failures: [String] = []
        /// The renderers whose descriptions could be read, for finding the receiver.
        public var renderers: [Renderer] = []
    }

    public static func run(
        transport: some SSDPTransport, subnets: LocalSubnets, seconds: Double = searchSeconds,
        fetchTimeoutSeconds: Double = LocalHTTPClient.timeoutSeconds
    ) async -> Result {
        var result = Result()
        let recording = RecordingTransport(base: transport)
        let search: SSDPSearch.Result
        do {
            search = try await SSDPSearch.run(
                searchTarget: RendererDiscovery.mediaRenderer, transport: recording,
                subnets: subnets, seconds: seconds)
        } catch {
            result.failures.append("the SSDP search failed: \(error)")
            return result
        }
        let datagrams = recording.datagrams
        if datagrams.isEmpty {
            result.failures.append("no device answered the SSDP search")
        } else {
            result.files.append(CaptureFile(name: "ssdp.txt", bytes: ssdpText(datagrams)))
        }
        for problem in search.problems { result.failures.append("\(problem)") }
        if search.moreProblems > 0 {
            result.failures.append("\(search.moreProblems) more replies were ignored")
        }
        // A device answers once per service it offers, all with one description.
        var seen: Set<LocalURL> = []
        let locations = search.replies.map(\.location).filter { seen.insert($0).inserted }
        for (index, location) in locations.enumerated() {
            await capture(
                location, number: index + 1, timeoutSeconds: fetchTimeoutSeconds, into: &result)
        }
        return result
    }

    private static func capture(
        _ location: LocalURL, number: Int, timeoutSeconds: Double, into result: inout Result
    ) async {
        let live = Fetcher.live(timeoutSeconds: timeoutSeconds, keepingRefusals: true)
        let log = FetchLog()
        let recording = Fetcher(
            get: { url throws(LocalNetworkError) in
                do throws(LocalNetworkError) {
                    return log.set(description: try await live.get(url))
                } catch {
                    log.keep(error, as: "description")
                    throw error
                }
            },
            post: { url, fields, body throws(LocalNetworkError) in
                do throws(LocalNetworkError) {
                    return log.set(protocolInfo: try await live.post(url, fields, body))
                } catch {
                    log.keep(error, as: "protocolinfo")
                    throw error
                }
            })
        switch await RendererDiscovery.renderer(at: location, fetcher: recording) {
        case .success(let renderer):
            result.renderers.append(renderer)
            if let why = renderer.formatsProblem {
                result.failures.append("\(number)-protocolinfo.xml: \(why)")
            }
            if let topology = renderer.sonos?.topology {
                await captureTopology(topology, number: number, fetcher: live, into: &result)
            }
        case .failure(let problem):
            result.failures.append("\(problem)")
        }
        let (description, protocolInfo) = log.fetched
        for (kind, status, raw) in log.refusals {
            result.files.append(
                CaptureFile(name: "\(number)-\(kind)-\(status).txt", bytes: raw))
        }
        if let description {
            result.files.append(CaptureFile(name: "\(number)-description.xml", bytes: description))
            await captureServices(
                description, at: location, number: number, fetcher: live, into: &result)
        }
        if let protocolInfo {
            result.files.append(
                CaptureFile(name: "\(number)-protocolinfo.xml", bytes: protocolInfo))
        }
    }

    /// A Sonos player's `GetZoneGroupState` reply, which names its household's groups.
    private static func captureTopology(
        _ control: LocalURL, number: Int, fetcher: Fetcher, into result: inout Result
    ) async {
        let file = "\(number)-zonegroupstate.xml"
        let request = ZoneGroupTopology.request
        do {
            let bytes = try await fetcher.post(control, request.fields, request.body)
            result.files.append(CaptureFile(name: file, bytes: bytes))
        } catch let LocalNetworkError.statusReply(status, raw) {
            result.files.append(
                CaptureFile(name: "\(number)-zonegroupstate-\(status).txt", bytes: raw))
            result.failures.append("\(file): the reply's status is \(status)")
        } catch {
            result.failures.append("\(file): \(error)")
        }
    }

    private static func captureServices(
        _ description: [UInt8], at location: LocalURL, number: Int, fetcher: Fetcher,
        into result: inout Result
    ) async {
        let listed: [DeviceDescription.Service]
        do {
            listed = try DeviceDescription(description).devices.flatMap(\.services)
        } catch {
            result.failures.append(
                "\(number)-description.xml: its services can't be listed: \(error)")
            return
        }
        for name in services {
            let file = "\(number)-\(name)-scpd.xml"
            // A service type is urn:schemas-upnp-org:service:<name>:<version>.
            guard
                let service = listed.first(where: {
                    $0.serviceType.split(separator: ":").dropFirst(3).first == Substring(name)
                })
            else {
                result.failures.append("\(file): the device lists no \(name)")
                continue
            }
            guard let scpd = service.scpdURL else {
                result.failures.append("\(file): its \(name) lists no SCPDURL")
                continue
            }
            do {
                let bytes = try await fetcher.get(try location.resolving(scpd))
                result.files.append(CaptureFile(name: file, bytes: bytes))
            } catch let LocalNetworkError.statusReply(status, raw) {
                result.files.append(
                    CaptureFile(name: "\(number)-\(name)-scpd-\(status).txt", bytes: raw))
                result.failures.append("\(file): the reply's status is \(status)")
            } catch {
                result.failures.append("\(file): \(error)")
            }
        }
    }

    /// Each reply under a line saying where it came from, bytes as received.
    private static func ssdpText(_ datagrams: [SSDPDatagram]) -> [UInt8] {
        var bytes: [UInt8] = []
        for (index, datagram) in datagrams.enumerated() {
            bytes += Array(
                "# reply \(index + 1) from \(datagram.source), \(datagram.bytes.count) bytes\n"
                    .utf8)
            bytes += datagram.bytes
            bytes += Array("\n".utf8)
        }
        return bytes
    }
}

/// Passes a search through and keeps every datagram it got back, the ones discovery ignores
/// included.
private final class RecordingTransport: SSDPTransport, @unchecked Sendable {
    private let base: any SSDPTransport
    private let lock = NSLock()
    private var kept: [SSDPDatagram] = []

    init(base: some SSDPTransport) { self.base = base }

    var datagrams: [SSDPDatagram] { lock.withLock { kept } }

    func search(_ request: [UInt8], from interfaces: [NetworkInterface], seconds: Double)
        async throws(LocalNetworkError) -> [SSDPDatagram]
    {
        let found = try await base.search(request, from: interfaces, seconds: seconds)
        lock.withLock { kept += found }
        return found
    }
}

/// The raw bytes one renderer's fetches got back.
private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var description: [UInt8]?
    private var protocolInfo: [UInt8]?
    private var kept: [(kind: String, status: Int, raw: [UInt8])] = []

    /// Returns `bytes`, so a fetcher can record as it passes them on.
    func set(description bytes: [UInt8]) -> [UInt8] {
        lock.withLock { description = bytes }
        return bytes
    }

    func set(protocolInfo bytes: [UInt8]) -> [UInt8] {
        lock.withLock { protocolInfo = bytes }
        return bytes
    }

    /// Keeps what a refusing device sent, under the kind of document that was asked for.
    func keep(_ error: LocalNetworkError, as kind: String) {
        guard case .statusReply(let status, let raw) = error else { return }
        lock.withLock { kept.append((kind, status, raw)) }
    }

    var refusals: [(kind: String, status: Int, raw: [UInt8])] { lock.withLock { kept } }

    var fetched: (description: [UInt8]?, protocolInfo: [UInt8]?) {
        lock.withLock { (description, protocolInfo) }
    }
}
