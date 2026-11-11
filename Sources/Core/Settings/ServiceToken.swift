/// `recommender.token`: the bearer token music-recommender's API takes (ADR 0144), a secret
/// kept as the Discogs token is: only in the config file, and only in the service's
/// `Authorization` header. It prints as `<service token>`.
public typealias ServiceToken = Secret<ServiceTokenRole>

public enum ServiceTokenRole: SecretRole {
    /// The longest token taken.
    static let lengthCap = 1024

    public static var redacted: String { "<service token>" }
    public static var typeName: String { "a service token (text)" }

    public static func problem(_ secret: String) -> String? {
        let visible = secret.utf8.allSatisfy { (0x21...0x7E).contains($0) }
        return visible && (1...lengthCap).contains(secret.utf8.count)
            ? nil
            : "the token must be 1 to \(lengthCap) visible ASCII characters, with no spaces"
    }
}
