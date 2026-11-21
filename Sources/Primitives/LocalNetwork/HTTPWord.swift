/// HTTP's methods, field names and values as the servers and the clients send them, each
/// spelled once.
public enum HTTPWord {
    public static let post = "POST"
    public static let contentType = "Content-Type"
    static let contentLength = "Content-Length"
    static let connection = "Connection"
    public static let cacheControl = "Cache-Control"
    /// `Cache-Control` for a reply no cache keeps.
    public static let noStore = "no-store"
    /// `Connection` for a connection that ends after its reply.
    static let close = "close"
    public static let json = "application/json"
}
