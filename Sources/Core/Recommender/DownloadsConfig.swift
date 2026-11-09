import Foundation
import LocalNetwork

/// `downloads/config`'s reply: whether the downloads are on, and where slskd's web page is.
package struct DownloadsConfig: Equatable, Sendable, Decodable {
    package var enabled: Bool
    /// Why the downloads are off, in words; nil while they're on.
    var offReason: String?
    var formatPolicies: [FormatPolicy]
    var defaultFormatPolicy: FormatPolicy
    /// The last component of the service's staging folder; nil while the downloads are off.
    var stagingDirName: String?
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
        enabled = try container.decode(Bool.self, forKey: .enabled)
        offReason = try container.decode(String?.self, forKey: .offReason)
        formatPolicies = try container.decode([FormatPolicy].self, forKey: .formatPolicies)
        defaultFormatPolicy = try container.decode(FormatPolicy.self, forKey: .defaultFormatPolicy)
        stagingDirName = try container.decode(String?.self, forKey: .stagingDirName)
        slskdURL = try container.decode(String?.self, forKey: .slskdURL)
    }

    /// The hosts that mean slskd runs on the service's own Mac.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// slskd's page as this Mac opens it: a loopback host is the service's Mac, so `service`,
    /// the address the player reaches the service at, takes its place, with the scheme and port
    /// kept. Nil without a URL, or for one that isn't http or https with a host.
    package func slskdPage(reachedAt service: IPAddress) -> URL? {
        guard let text = slskdURL, var parts = URLComponents(string: text),
            let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = parts.host, !host.isEmpty
        else { return nil }
        if Self.loopbackHosts.contains(host.lowercased()) {
            parts.percentEncodedHost = service.urlHost
        }
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
