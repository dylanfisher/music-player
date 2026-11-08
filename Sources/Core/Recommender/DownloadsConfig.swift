/// `downloads/config`'s reply: whether the downloads are on, and the policies they take.
struct DownloadsConfig: Equatable, Sendable, Decodable {
    var enabled: Bool
    /// Why the downloads are off, in words; nil while they're on.
    var offReason: String?
    var formatPolicies: [FormatPolicy]
    var defaultFormatPolicy: FormatPolicy
    /// The last component of the service's staging folder, for Settings to compare with
    /// `import.stagingFolder`; nil while the downloads are off.
    var stagingDirName: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, enabled
        case offReason = "off_reason"
        case formatPolicies = "format_policies"
        case defaultFormatPolicy = "default_format_policy"
        case stagingDirName = "staging_dir_name"
    }

    init(
        enabled: Bool, offReason: String?, formatPolicies: [FormatPolicy],
        defaultFormatPolicy: FormatPolicy, stagingDirName: String?
    ) {
        self.enabled = enabled
        self.offReason = offReason
        self.formatPolicies = formatPolicies
        self.defaultFormatPolicy = defaultFormatPolicy
        self.stagingDirName = stagingDirName
    }

    init(from decoder: any Decoder) throws {
        let container = try okContainer(decoder, CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        offReason = try container.decode(String?.self, forKey: .offReason)
        formatPolicies = try container.decode([FormatPolicy].self, forKey: .formatPolicies)
        defaultFormatPolicy = try container.decode(FormatPolicy.self, forKey: .defaultFormatPolicy)
        stagingDirName = try container.decode(String?.self, forKey: .stagingDirName)
    }
}
