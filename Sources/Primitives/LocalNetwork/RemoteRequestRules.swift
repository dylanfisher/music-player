/// What the remote server does with a request's head, decided before the handler sees it
/// (ADR 0214).
enum RemoteRoute: Equatable {
    case refuse(HTTPStatus)
    /// A CORS preflight from an origin that may ask.
    case preflight(origin: String)
    /// Read a body of `bodyLength` bytes, then hand the request on. `origin` is the request's
    /// `Origin` when it sent an allowed one, for the reply's CORS fields.
    case request(bodyLength: Int, origin: String?)
}

/// The caps and names a request's head is checked against.
struct RemoteRules: Sendable {
    static let headBytes = 8 * 1024
    static let bodyBytes = 16 * 1024
    static let targetBytes = 2048

    /// `host:port` for each name the server may be reached by, lowercased: its addresses and
    /// its `.local` name.
    let authorities: Set<String>
    /// Whether a page from this origin, another instance's, may call the server.
    let allowsOrigin: @Sendable (String) -> Bool

    init(authorities: [String], allowsOrigin: @escaping @Sendable (String) -> Bool) {
        self.authorities = Set(authorities.map { $0.lowercased() })
        self.allowsOrigin = allowsOrigin
    }

    /// The origin is a page from this server itself, or one `allowsOrigin` takes.
    func allows(origin: String) -> Bool {
        let lowered = origin.lowercased()
        if lowered.hasPrefix(Self.scheme), authorities.contains(String(lowered.dropFirst(7))) {
            return true
        }
        return allowsOrigin(lowered)
    }

    private static let scheme = "http://"

    func route(_ head: HTTPHead) -> RemoteRoute {
        let method = head.start[0]
        guard ["GET", HTTPWord.post, "OPTIONS"].contains(method) else {
            return .refuse(.methodNotAllowed)
        }
        guard head.start[2] == HTTPHead.version || head.start[2] == HTTPHead.version10 else {
            return .refuse(.badRequest)
        }
        let target = head.start[1]
        guard target.first == "/", target.utf8.count <= Self.targetBytes else {
            return .refuse(.badRequest)
        }
        // DNS rebinding: a page that resolved its own name to this address still sends its name.
        guard let host = head.value(HTTPHead.host), authorities.contains(host.lowercased()) else {
            return .refuse(.badRequest)
        }
        guard head.values(HTTPHead.transferEncoding).isEmpty else { return .refuse(.badRequest) }
        let lengths = head.values(HTTPHead.contentLength)
        guard lengths.count <= 1 else { return .refuse(.badRequest) }
        var length = 0
        if let text = lengths.first {
            guard !text.isEmpty, text.utf8.count <= 8, text.utf8.allSatisfy(isASCIIDigit),
                let parsed = Int(text)
            else { return .refuse(.badRequest) }
            length = parsed
        }
        guard length <= Self.bodyBytes else { return .refuse(.payloadTooLarge) }
        guard method == HTTPWord.post || length == 0 else { return .refuse(.badRequest) }
        let origins = head.values("origin")
        guard origins.count <= 1 else { return .refuse(.forbidden) }
        if let origin = origins.first, !allows(origin: origin) { return .refuse(.forbidden) }
        if method == "OPTIONS" {
            guard let origin = origins.first else { return .refuse(.forbidden) }
            return .preflight(origin: origin)
        }
        return .request(bodyLength: length, origin: origins.first)
    }
}

private func isASCIIDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

/// What the remote server answers `request` with, from its bytes alone: the status of a
/// refusal or a preflight, or 200 for one it would hand on with its whole body. Nil while the
/// head or the body is incomplete. The fuzzer drives the head parser and the rules through this,
/// as a request on the wire would.
package func answer(
    toRemoteRequest request: [UInt8], authority: String, allowedOrigin: String
) -> (status: Int, bodyLength: Int)? {
    let rules = RemoteRules(authorities: [authority], allowsOrigin: { $0 == allowedOrigin })
    switch HTTPHead.parse(request[...], cap: RemoteRules.headBytes) {
    case .incomplete: return nil
    case .tooLarge: return (HTTPStatus.headersTooLarge.rawValue, 0)
    case .malformed: return (HTTPStatus.badRequest.rawValue, 0)
    case .head(let head, let length):
        switch rules.route(head) {
        case .refuse(let status): return (status.rawValue, 0)
        case .preflight: return (HTTPStatus.noContent.rawValue, 0)
        case .request(let bodyLength, _):
            guard request.count - length >= bodyLength else { return nil }
            return (HTTPStatus.ok.rawValue, bodyLength)
        }
    }
}
