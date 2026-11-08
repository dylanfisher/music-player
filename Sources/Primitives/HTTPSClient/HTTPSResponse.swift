/// A reply as `HTTPSClient` received it: any status, a redirect among them.
public struct HTTPSResponse: Sendable, Equatable {
    public var status: Int
    /// By lowercased name.
    public var headers: [String: String]
    public var body: [UInt8]

    public init(status: Int, headers: [String: String], body: [UInt8]) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
        self.body = body
    }

    /// The header's value, by its name in any case.
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}
