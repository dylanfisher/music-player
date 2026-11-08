/// A report or a claim the player sends for one job through `downloads/handoff`.
enum HandoffEvent: Equatable, Sendable, Encodable {
    /// The stages the player runs, which only it reports as failed.
    enum Stage: String, Equatable, Sendable, Encodable {
        case tag, move, delete, carry
    }

    /// Takes or renews the tagging lease for 10 minutes; renewed every 3 while tagging.
    case lease
    case releaseLease
    /// What the tag run found; `reasons` for `discrepancy` and `error`.
    case tagging(DownloadJob.Tagging)
    /// Takes or renews the review claim for 24 hours; `takeOver` is Resume Here, for an
    /// `approved` or `importing` job another Mac left.
    case claim(takeOver: Bool)
    /// Gives up the review claim.
    case release
    case approved
    case importing
    case imported
    case rejected
    case failed(Stage, reason: String)

    private enum CodingKeys: String, CodingKey {
        case type, status, reasons
        case takeOver = "take_over"
        case stage, reason
    }

    /// `event.type`, one for each case.
    private enum EventType: String, Encodable {
        case lease
        case releaseLease = "release_lease"
        case tagging, claim, release, approved, importing, imported, rejected, failed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let type: EventType
        switch self {
        case .lease: type = .lease
        case .releaseLease: type = .releaseLease
        case .tagging(let tagging):
            type = .tagging
            try container.encode(tagging.status, forKey: .status)
            try container.encode(tagging.reasons, forKey: .reasons)
        case .claim(let takeOver):
            type = .claim
            if takeOver { try container.encode(true, forKey: .takeOver) }
        case .release: type = .release
        case .approved: type = .approved
        case .importing: type = .importing
        case .imported: type = .imported
        case .rejected: type = .rejected
        case .failed(let stage, let reason):
            type = .failed
            try container.encode(stage, forKey: .stage)
            try container.encode(reason, forKey: .reason)
        }
        try container.encode(type, forKey: .type)
    }
}
