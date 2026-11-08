import Foundation

/// A report or a claim the player sends for one job through `downloads/handoff`.
package enum HandoffEvent: Equatable, Sendable, Codable {
    /// The stages the player runs, which only it reports as failed.
    package enum Stage: String, Equatable, Sendable, Codable {
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
    private enum EventType: String, Codable {
        case lease
        case releaseLease = "release_lease"
        case tagging, claim, release, approved, importing, imported, rejected, failed
    }

    package func encode(to encoder: any Encoder) throws {
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

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .lease: self = .lease
        case .releaseLease: self = .releaseLease
        case .tagging:
            self = .tagging(
                DownloadJob.Tagging(
                    status: try container.decode(DownloadJob.Tagging.Status.self, forKey: .status),
                    reasons: try container.decode([String].self, forKey: .reasons)))
        case .claim:
            self = .claim(
                takeOver: try container.decodeIfPresent(Bool.self, forKey: .takeOver) ?? false)
        case .release: self = .release
        case .approved: self = .approved
        case .importing: self = .importing
        case .imported: self = .imported
        case .rejected: self = .rejected
        case .failed:
            self = .failed(
                try container.decode(Stage.self, forKey: .stage),
                reason: try container.decode(String.self, forKey: .reason))
        }
    }

    /// The event a report in the outbox holds, from its `json`. Refused unless the text is
    /// exactly an event's encoding, so nothing but this player's own reports is sent.
    package init(json: String) throws {
        let event = try replyDecoder.decode(HandoffEvent.self, from: Data(json.utf8))
        let object = { (text: String) in
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        }
        guard try object(event.json) == object(json) else {
            throw RecommenderError.Kind.unreadable("\(json) isn't a handoff event's encoding")
        }
        self = event
    }

    /// The event as a report in the outbox holds it, its keys sorted, so a report queued twice
    /// is the same text.
    package var json: String {
        do {
            return String(decoding: try requestEncoder.encode(self), as: UTF8.self)
        } catch {
            preconditionFailure("an event always encodes: \(error)")
        }
    }
}
