import Foundation
import LocalNetwork

/// `downloads/config`'s reply, of which the player reads where slskd's web page is.
package struct DownloadsConfig: Equatable, Sendable, Decodable {
    /// slskd's web page as the service reaches it; nil while the downloads are off.
    var slskdURL: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, enabled
        case offReason = "off_reason"
        case formatPolicies = "format_policies"
        case defaultFormatPolicy = "default_format_policy"
        case stagingDirName = "staging_dir_name"
        case slskdURL = "slskd_url"
    }

    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        // Decoded only to hold the reply to its shape: a missing or mistyped field fails it.
        _ = try container.decode(Bool.self, forKey: .enabled)
        _ = try container.decode(String?.self, forKey: .offReason)
        _ = try container.decode([FormatPolicy].self, forKey: .formatPolicies)
        _ = try container.decode(FormatPolicy.self, forKey: .defaultFormatPolicy)
        _ = try container.decode(String?.self, forKey: .stagingDirName)
        slskdURL = try container.decode(String?.self, forKey: .slskdURL)
    }

    /// Whether `host` is slskd on the service's own Mac: `localhost`, any 127.0.0.0/8 address,
    /// `::1`, or the unspecified `0.0.0.0` and `::`, which a server listening on every
    /// interface reports.
    static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "localhost." { return true }
        let literal =
            name.hasPrefix("[") && name.hasSuffix("]") ? String(name.dropFirst().dropLast()) : name
        switch IPAddress(literal) {
        case .v4(let bytes): return bytes[0] == 127 || bytes.allSatisfy { $0 == 0 }
        case .v6(let bytes, _):
            return bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] <= 1
        case nil: return false
        }
    }

    /// slskd's page as this Mac opens it: a loopback host is the service's Mac, so `service`,
    /// the address the player reaches the service at, takes its place, with the scheme and port
    /// kept. Any user, password, query or fragment is dropped, so none is opened, shown or
    /// logged. Nil without a URL, or for one that isn't http or https with a host.
    package func slskdPage(reachedAt service: IPAddress) -> URL? {
        guard let text = slskdURL, var parts = URLComponents(string: text),
            let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = parts.host, !host.isEmpty
        else { return nil }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        if Self.isLoopback(host) { parts.percentEncodedHost = service.urlHost }
        return parts.url
    }
}

extension RecommenderClient {
    /// slskd's web page, from `downloads/config`, with this client's address in place of a
    /// loopback host; nil while the service reports none or one that can't be opened.
    package func slskdPage() async throws(RecommenderError) -> URL? {
        try await call("/v1/downloads/config", body: EmptyRequest(), as: DownloadsConfig.self)
            .slskdPage(reachedAt: host)
    }
}
