import LocalNetwork

/// Finds the MediaRenderers on the local subnets: an SSDP search, then each renderer's
/// description and `GetProtocolInfo`, each fetched from the subnet its reply came from
/// (ADR 0039).
public enum RendererDiscovery {
    static let mediaRenderer = "urn:schemas-upnp-org:device:MediaRenderer:1"
    /// How long a search listens for replies.
    public static let searchSeconds = 3.0
    /// Most problems one discovery lists; the rest are counted.
    static let problemCap = 20

    public struct Outcome: Equatable, Sendable {
        public var renderers: [Renderer] = []
        public var problems: [RendererProblem] = []
        public var moreProblems = 0

        mutating func add(_ problem: RendererProblem) {
            if problems.count < problemCap {
                problems.append(problem)
            } else {
                moreProblems += 1
            }
        }
    }

    public static func discover(
        transport: some SSDPTransport, subnets: LocalSubnets,
        seconds: Double = searchSeconds,
        fetchTimeoutSeconds: Double = LocalHTTPClient.timeoutSeconds
    ) async throws(LocalNetworkError) -> Outcome {
        let search = try await SSDPSearch.run(
            searchTarget: mediaRenderer, transport: transport, subnets: subnets, seconds: seconds)
        var outcome = Outcome()
        for problem in search.problems { outcome.add(.search(problem)) }
        outcome.moreProblems += search.moreProblems
        let found = await withTaskGroup(of: Result<Renderer, RendererProblem>.self) { group in
            for reply in search.replies {
                group.addTask {
                    await renderer(
                        at: reply.location, fetcher: .live(timeoutSeconds: fetchTimeoutSeconds))
                }
            }
            var found: [Result<Renderer, RendererProblem>] = []
            for await result in group { found.append(result) }
            return found
        }
        var renderers: [Renderer] = []
        for result in found {
            switch result {
            case .success(let renderer): renderers.append(renderer)
            case .failure(let problem): outcome.add(problem)
            }
        }
        let (kept, conflicts) = oneEachByUDN(renderers)
        outcome.renderers = kept
        for conflict in conflicts { outcome.add(conflict) }
        outcome.renderers.sort { ($0.name, $0.udn) < ($1.name, $1.udn) }
        return outcome
    }

    /// One renderer per UDN, the first found. A UDN is one device, so one given from two
    /// addresses means a host is posing as another; neither can be told for the real one, so
    /// neither is kept, and the conflict is reported.
    static func oneEachByUDN(_ renderers: [Renderer]) -> ([Renderer], [RendererProblem]) {
        var kept: [Renderer] = []
        var conflicts: [RendererProblem] = []
        var udns: [String] = []
        for renderer in renderers where !udns.contains(renderer.udn) { udns.append(renderer.udn) }
        for udn in udns {
            let claiming = renderers.filter { $0.udn == udn }
            let addresses = Set(claiming.map(\.address))
            if addresses.count == 1 {
                kept.append(claiming[0])
            } else {
                conflicts.append(.conflictingUDN(udn, addresses.map { "\($0)" }.sorted()))
            }
        }
        return (kept, conflicts)
    }

    /// The renderer whose description is at `location`. A failed `GetProtocolInfo` still
    /// gives the renderer, with no formats, since receiver control doesn't need them.
    static func renderer(at location: LocalURL, fetcher: Fetcher) async
        -> Result<Renderer, RendererProblem>
    {
        let description: DeviceDescription
        do {
            description = try DeviceDescription(
                await fetcher.get(location))
        } catch {
            return .failure(.description(location, "\(error)"))
        }
        guard let device = description.device(ofType: mediaRenderer), !device.udn.isEmpty else {
            return .failure(.description(location, "it has no MediaRenderer with a UDN"))
        }
        var formats: [ProtocolInfo] = []
        var problem: String?
        if let service = device.service(ofType: GetProtocolInfo.serviceType) {
            do {
                let control = try location.resolving(service.controlURL)
                formats = try GetProtocolInfo.sink(
                    await fetcher.post(
                        control, GetProtocolInfo.request.fields, GetProtocolInfo.request.body))
            } catch {
                problem = "\(error)"
            }
        } else {
            problem = "it has no ConnectionManager"
        }
        var transport: Renderer.Transport?
        var transportProblem: String?
        if let service = device.service(ofType: AVTransport.serviceType) {
            do throws(LocalURL.Refusal) {
                transport = Renderer.Transport(
                    control: try location.resolving(service.controlURL),
                    description: try service.scpdURL.map(location.resolving))
            } catch {
                transportProblem = "its AVTransport can't be used: \(error)"
            }
        } else {
            transportProblem = "it has no AVTransport"
        }
        return .success(
            Renderer(
                udn: device.udn, name: device.name, manufacturer: device.manufacturer,
                model: device.model, location: location, sinkFormats: formats,
                formatsProblem: problem, transport: transport, transportProblem: transportProblem))
    }
}

/// How a renderer's documents are fetched. Capture passes one that keeps the raw bytes.
struct Fetcher: Sendable {
    var get: @Sendable (LocalURL) async throws(LocalNetworkError) -> [UInt8]
    var post:
        @Sendable (LocalURL, [(String, String)], [UInt8]) async throws(LocalNetworkError) -> [UInt8]

    static func live(timeoutSeconds: Double, keepingRefusals: Bool = false) -> Fetcher {
        Fetcher(
            get: { url throws(LocalNetworkError) in
                try await LocalHTTPClient.get(
                    url, timeoutSeconds: timeoutSeconds, keepingRefusals: keepingRefusals)
            },
            post: { url, fields, body throws(LocalNetworkError) in
                try await LocalHTTPClient.post(
                    url, fields: fields, body: body, timeoutSeconds: timeoutSeconds,
                    keepingRefusals: keepingRefusals)
            })
    }
}

/// What discovery left out, and why. Each is hostile input or a device that misbehaved, so
/// it's reported and the rest carries on.
public enum RendererProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case search(SSDPProblem)
    case description(LocalURL, String)
    /// Devices at more than one address gave the same UDN.
    case conflictingUDN(String, [String])

    public var description: String {
        switch self {
        case .search(let problem): "\(problem)"
        case .description(let url, let why): "the description at \(url) was ignored: \(why)"
        case .conflictingUDN(let udn, let addresses):
            "\(udn) answered from \(addresses.joined(separator: " and ")), so neither is used"
        }
    }
}
