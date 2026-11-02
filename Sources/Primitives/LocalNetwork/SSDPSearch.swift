/// One datagram a search got back, and where from.
public struct SSDPDatagram: Sendable, Equatable {
    public let bytes: [UInt8]
    public let source: IPAddress
}

/// Sends a search and gathers what comes back. The real one is `UDPSearchTransport`; tests
/// pass their own, so nothing reaches the LAN.
public protocol SSDPTransport: Sendable {
    /// Sends `request` out of each of `interfaces` and returns every datagram that arrives
    /// within `seconds`.
    func search(_ request: [UInt8], from interfaces: [NetworkInterface], seconds: Double)
        async throws(LocalNetworkError) -> [SSDPDatagram]
}

/// A device that answered a search, and the interface whose subnet it's on.
public struct SSDPReply: Sendable, Equatable {
    /// The device's description, checked to be on the subnet the reply came from.
    public let location: LocalURL
    public let searchTarget: String
    /// The unique service name, which tells a device's replies apart from another's.
    let usn: String
    public let source: IPAddress
}

/// A reply a search ignored, and why. Replies are hostile input, so each is reported, never
/// fatal.
public enum SSDPProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case offSubnet(IPAddress)
    case tooLarge(IPAddress, bytes: Int)
    case malformed(IPAddress, String)
    case badLocation(IPAddress, LocalURL.Refusal)

    public var description: String {
        switch self {
        case .offSubnet(let source): "a reply from \(source), off the local subnet, was ignored"
        case .tooLarge(let source, let bytes):
            "a reply of \(bytes) bytes from \(source) is over the \(SSDPSearch.replyCap)-byte cap"
        case .malformed(let source, let why): "a reply from \(source) was ignored: \(why)"
        case .badLocation(let source, let refusal):
            "a reply from \(source) was ignored: \(refusal)"
        }
    }
}

/// A search for devices of one type with SSDP's M-SEARCH (ADR 0039).
public enum SSDPSearch {
    /// SSDP's multicast group and port, where a search goes.
    public static let multicastGroup = IPAddress("239.255.255.250")!
    public static let port: UInt16 = 1900
    /// Most bytes a reply may have.
    static let replyCap = 64 * 1024
    /// Most distinct devices one search keeps.
    static let replyCountCap = 64
    /// Most problems one search lists; the rest are counted.
    static let problemCap = 20

    /// The M-SEARCH for `searchTarget`, asking for replies within `waitSeconds`.
    static func request(searchTarget: String, waitSeconds: Int) -> [UInt8] {
        let lines = [
            "M-SEARCH * HTTP/1.1", "HOST: \(multicastGroup):\(port)", "MAN: \"ssdp:discover\"",
            "MX: \(waitSeconds)", "ST: \(searchTarget)",
        ]
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// What a search found: one reply per device, and what was ignored.
    public struct Result: Sendable, Equatable {
        public var replies: [SSDPReply] = []
        public var problems: [SSDPProblem] = []
        /// Problems past `problemCap`, counted.
        public var moreProblems = 0
    }

    /// Searches for `searchTarget` from every interface in `subnets` and keeps the replies
    /// from a local subnet that point at it.
    public static func run(
        searchTarget: String, transport: some SSDPTransport, subnets: LocalSubnets,
        seconds: Double
    ) async throws(LocalNetworkError) -> Result {
        let datagrams = try await transport.search(
            request(searchTarget: searchTarget, waitSeconds: max(1, Int(seconds))),
            from: subnets.interfaces, seconds: seconds)
        return gather(datagrams, searchTarget: searchTarget, subnets: subnets)
    }

    static func gather(_ datagrams: [SSDPDatagram], searchTarget: String, subnets: LocalSubnets)
        -> Result
    {
        var result = Result()
        var seen: Set<String> = []
        func problem(_ problem: SSDPProblem) {
            if result.problems.count < problemCap {
                result.problems.append(problem)
            } else {
                result.moreProblems += 1
            }
        }
        for datagram in datagrams {
            switch reply(datagram, searchTarget: searchTarget, subnets: subnets) {
            case .success(let reply):
                guard reply.searchTarget == searchTarget, result.replies.count < replyCountCap,
                    seen.insert(reply.usn).inserted
                else { continue }
                result.replies.append(reply)
            case .failure(let refusal):
                problem(refusal)
            }
        }
        return result
    }

    /// One datagram as a reply, or why it isn't one.
    static func reply(_ datagram: SSDPDatagram, searchTarget: String, subnets: LocalSubnets)
        -> Swift.Result<SSDPReply, SSDPProblem>
    {
        let source = datagram.source
        guard let interface = subnets.interface(holding: source) else {
            return .failure(.offSubnet(source))
        }
        guard datagram.bytes.count <= replyCap else {
            return .failure(.tooLarge(source, bytes: datagram.bytes.count))
        }
        let head: HTTPHead
        switch HTTPHead.parse(datagram.bytes[...], cap: replyCap) {
        case .head(let parsed, _): head = parsed
        case .incomplete: return .failure(.malformed(source, "its head doesn't end"))
        case .tooLarge: return .failure(.tooLarge(source, bytes: datagram.bytes.count))
        case .malformed(let why): return .failure(.malformed(source, why))
        }
        guard head.start[0] == HTTPHead.version, head.start[1] == "200" else {
            return .failure(.malformed(source, "it isn't a 200 reply"))
        }
        guard let locationText = head.value("location"), let target = head.value("st"),
            let usn = head.value("usn"), !usn.isEmpty
        else { return .failure(.malformed(source, "it lacks one LOCATION, ST and USN")) }
        do throws(LocalURL.Refusal) {
            let location = try LocalURL(locationText, on: interface)
            return .success(
                SSDPReply(location: location, searchTarget: target, usn: usn, source: source))
        } catch {
            return .failure(.badLocation(source, error))
        }
    }
}
