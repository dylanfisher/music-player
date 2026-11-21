/// A request the remote server took whole, once its head passed `RemoteRules` (ADR 0214).
public struct RemoteRequest: Sendable {
    public let method: String
    /// The target before any `?`.
    public let path: String
    /// The target after the `?`, nil without one.
    public let query: String?
    public let body: [UInt8]
    public let peer: IPAddress
    /// Field names lowercased, in order.
    let fields: [(name: String, value: String)]

    init(head: HTTPHead, body: [UInt8], peer: IPAddress) {
        method = head.start[0]
        let target = head.start[1]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            query = String(target[target.index(after: mark)...])
        } else {
            path = target
            query = nil
        }
        self.body = body
        self.peer = peer
        fields = head.fields
    }

    /// The value of the one field named `name`, any case; nil when there's none or more than one.
    public func field(_ name: String) -> String? {
        let lowered = name.lowercased()
        let found = fields.filter { $0.name == lowered }
        return found.count == 1 ? found[0].value : nil
    }
}

/// What the handler answers a request with.
public enum RemoteResponse: Sendable {
    case reply(RemoteReply)
    /// A Server-Sent Events stream: each element goes out as it comes, until the stream ends or
    /// the connection closes, when the server calls `stop` once.
    case events(AsyncStream<[UInt8]>, stop: @Sendable () -> Void)
}

/// A whole reply. The server adds the length, CORS, keep-alive and, when asked, gzip.
public struct RemoteReply: Sendable {
    public var status: HTTPStatus
    public var contentType: String?
    public var body: [UInt8]
    public var fields: [(String, String)]

    public init(
        _ status: HTTPStatus, contentType: String? = nil, body: [UInt8] = [],
        fields: [(String, String)] = []
    ) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.fields = fields
    }
}
