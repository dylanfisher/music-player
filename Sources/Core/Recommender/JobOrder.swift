/// What a new job asks for besides its release: the policy, and for an upgrade what it
/// replaces. An upgrade takes only a lossless policy, so it can't ask for a lossy one.
package enum JobOrder: Equatable, Sendable {
    /// The policies an upgrade may ask for.
    package enum LosslessPolicy: Equatable, Sendable, CaseIterable {
        case flac, lossless

        package var formatPolicy: FormatPolicy {
            switch self {
            case .flac: .flac
            case .lossless: .lossless
            }
        }
    }

    /// Queued by the owner from a library album or a pasted release.
    case manual(FormatPolicy)
    /// Replaces a lossy library album with the same release.
    case upgrade(DownloadJob.Upgrade, LosslessPolicy)
}

/// `downloads/create`'s body.
struct CreateRequest: Encodable {
    var snapshot: ReleaseSnapshot
    var order: JobOrder

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case formatPolicy = "format_policy"
        case source, upgrade
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapshot, forKey: .snapshot)
        switch order {
        case .manual(let policy):
            try container.encode(policy, forKey: .formatPolicy)
            try container.encode(DownloadJob.Source.manual, forKey: .source)
            try container.encodeNil(forKey: .upgrade)
        case .upgrade(let upgrade, let policy):
            try container.encode(policy.formatPolicy, forKey: .formatPolicy)
            try container.encode(DownloadJob.Source.upgrade, forKey: .source)
            try container.encode(upgrade, forKey: .upgrade)
        }
    }
}
