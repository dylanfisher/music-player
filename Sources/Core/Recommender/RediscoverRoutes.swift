import StrictKeys

/// Rediscover: the day's albums of the library, and the Not Now marks that leave one out
/// (`docs/api.md` there, section Rediscover; ADR 0206).
extension RecommenderClient {
    /// The days Not Now leaves an album out for.
    package static let notNowDays = 30

    /// The albums of `day`, `YYYY-MM-DD` as `RediscoverDay.day(of:)` makes it. The service
    /// answers from scores it has, within the usual timeout.
    package func rediscover(day: String) async throws(RecommenderError) -> RediscoverDay {
        try await call("/v1/rediscover", body: RediscoverRequest(day: day), as: RediscoverDay.self)
    }

    /// Leaves the album the service names `id` out of Rediscover for `days` days from now, in
    /// place of a mark there, answering when the mark ends, in Unix seconds.
    package func notNow(_ id: String, days: Int = notNowDays) async throws(RecommenderError)
        -> Int
    {
        try await call(
            "/v1/rediscover/not_now", body: NotNowRequest(id: id, days: days),
            as: NotNowReply.self
        ).until
    }

    /// Removes the album's mark, answering whether there was one.
    package func undoNotNow(_ id: String) async throws(RecommenderError) -> Bool {
        try await call(
            "/v1/rediscover/not_now/undo", body: UndoNotNowRequest(id: id),
            as: UndoNotNowReply.self
        ).removed
    }
}

private struct RediscoverRequest: Encodable {
    var day: String
}

private struct NotNowRequest: Encodable {
    var id: String
    var days: Int
}

private struct UndoNotNowRequest: Encodable {
    var id: String
}

package struct NotNowReply: Decodable {
    var until: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, until
    }

    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        until = try container.decode(Int.self, forKey: .until)
    }
}

package struct UndoNotNowReply: Decodable {
    var removed: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, removed
    }

    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        removed = try container.decode(Bool.self, forKey: .removed)
    }
}
