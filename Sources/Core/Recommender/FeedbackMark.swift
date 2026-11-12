import StrictKeys

/// The owner's verdict on a recommended master or release, which leaves it out of every list
/// from the next request on (`docs/api.md` there, section Feedback).
package struct FeedbackMark: Equatable, Sendable, Decodable {
    package enum Verdict: String, Equatable, Sendable, Codable {
        case notInterested = "not_interested"
        case alreadyHave = "already_have"
    }

    /// Its place in `feedback/list`, from 1; every mark set takes the next.
    package var seq: Int
    package var kind: AlbumKind
    package var id: Int
    package var verdict: Verdict
    /// When it was set, in seconds since 1970.
    package var at: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case seq, kind, id, verdict, at
    }
}

extension FeedbackMark {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        kind = try container.decode(AlbumKind.self, forKey: .kind)
        id = try container.decode(Int.self, forKey: .id)
        verdict = try container.decode(Verdict.self, forKey: .verdict)
        at = try container.decode(Int.self, forKey: .at)
    }
}
