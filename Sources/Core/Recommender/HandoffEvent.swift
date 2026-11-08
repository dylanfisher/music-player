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
        switch self {
        case .lease, .releaseLease, .release, .approved, .importing, .imported, .rejected: break
        case .tagging(let tagging):
            try container.encode(tagging.status, forKey: .status)
            try container.encode(tagging.reasons.map(Self.fitted), forKey: .reasons)
        case .claim(let takeOver):
            if takeOver { try container.encode(true, forKey: .takeOver) }
        case .failed(let stage, let reason):
            try container.encode(stage, forKey: .stage)
            try container.encode(Self.fitted(reason), forKey: .reason)
        }
        try container.encode(type, forKey: .type)
    }

    /// The most characters the service takes in a string; it refuses a longer one, and a
    /// refused `failed` or `tagging` report would never be delivered.
    static let maxTextCharacters = 1000

    /// `text`, or its start with an ellipsis when it's over the service's limit. The service
    /// counts Unicode scalars, and the cut is between characters, so none is split.
    static func fitted(_ text: String) -> String {
        guard text.unicodeScalars.count > maxTextCharacters else { return text }
        var kept = ""
        var scalars = 0
        for character in text {
            scalars += character.unicodeScalars.count
            if scalars > maxTextCharacters - 1 { break }
            kept.append(character)
        }
        return kept + "…"
    }

    /// `event.type`, as the service names the event: "lease", "approved".
    package var name: String { type.rawValue }

    private var type: EventType {
        switch self {
        case .lease: .lease
        case .releaseLease: .releaseLease
        case .tagging: .tagging
        case .claim: .claim
        case .release: .release
        case .approved: .approved
        case .importing: .importing
        case .imported: .imported
        case .rejected: .rejected
        case .failed: .failed
        }
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
