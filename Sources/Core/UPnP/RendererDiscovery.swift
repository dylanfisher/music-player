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
                    await renderer(at: reply.location, timeoutSeconds: fetchTimeoutSeconds)
                }
            }
            var found: [Result<Renderer, RendererProblem>] = []
            for await result in group { found.append(result) }
            return found
        }
        var seen: Set<String> = []
        for result in found {
            switch result {
            case .success(let renderer):
                if seen.insert(renderer.udn).inserted { outcome.renderers.append(renderer) }
            case .failure(let problem):
                outcome.add(problem)
            }
        }
        outcome.renderers.sort { ($0.name, $0.udn) < ($1.name, $1.udn) }
        return outcome
    }

    /// The renderer whose description is at `location`. A failed `GetProtocolInfo` still
    /// gives the renderer, with no formats, since receiver control doesn't need them.
    static func renderer(at location: LocalURL, timeoutSeconds: Double) async
        -> Result<Renderer, RendererProblem>
    {
        let description: DeviceDescription
        do {
            description = try DeviceDescription(
                await LocalHTTPClient.get(location, timeoutSeconds: timeoutSeconds))
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
                    await LocalHTTPClient.post(
                        control, fields: GetProtocolInfo.fields, body: GetProtocolInfo.body,
                        timeoutSeconds: timeoutSeconds))
            } catch {
                problem = "\(error)"
            }
        } else {
            problem = "it has no ConnectionManager"
        }
        return .success(
            Renderer(
                udn: device.udn, name: device.name, manufacturer: device.manufacturer,
                model: device.model, location: location, sinkFormats: formats,
                formatsProblem: problem))
    }
}

/// What discovery left out, and why. Each is hostile input or a device that misbehaved, so
/// it's reported and the rest carries on.
public enum RendererProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case search(SSDPProblem)
    case description(LocalURL, String)

    public var description: String {
        switch self {
        case .search(let problem): "\(problem)"
        case .description(let url, let why): "the description at \(url) was ignored: \(why)"
        }
    }
}
