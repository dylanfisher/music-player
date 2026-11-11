import Foundation

/// A Discogs personal access token, a secret (ADR 0137). It is kept only in the config file and
/// goes only into the Discogs API's `Authorization` header. It prints as `<Discogs token>`.
public typealias DiscogsToken = Secret<DiscogsTokenRole>

public enum DiscogsTokenRole: SecretRole {
    public static var redacted: String { "<Discogs token>" }
    public static var typeName: String { "a Discogs token (text)" }

    /// A header value can't hold a line break or a character outside printable ASCII, and a
    /// token has no space.
    public static func problem(_ secret: String) -> String? {
        if secret.trimmingCharacters(in: .whitespaces).isEmpty { return "the token is empty" }
        guard secret.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return "the token has a space, a line break or a character outside printable ASCII"
        }
        return nil
    }
}
