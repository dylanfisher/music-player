import StrictKeys

/// Not Interested and Already Have: setting, removing and listing the marks.
extension RecommenderClient {
    /// Sets `verdict` on the master or release, in place of another; the same one again is
    /// answered with the mark unchanged.
    package func mark(_ kind: AlbumKind, _ id: Int, verdict: FeedbackMark.Verdict)
        async throws(RecommenderError) -> FeedbackMark
    {
        try await call(
            "/v1/feedback", body: MarkRequest(kind: kind, id: id, verdict: verdict),
            as: MarkReply.self
        ).feedback
    }

    /// Removes the verdict on the master or release, answering whether there was one.
    package func unmark(_ kind: AlbumKind, _ id: Int) async throws(RecommenderError) -> Bool {
        try await call(
            "/v1/feedback/undo", body: UnmarkRequest(kind: kind, id: id), as: UnmarkReply.self
        ).removed
    }

    /// Every mark, in ascending `seq`: each page of `feedback/list` until there are no more.
    package func marks() async throws(RecommenderError) -> [FeedbackMark] {
        var marks: [FeedbackMark] = []
        while true {
            let page = try await call(
                "/v1/feedback/list", body: MarksRequest(after: marks.last?.seq ?? 0),
                as: MarksReply.self)
            marks += page.feedback
            if !page.more || page.feedback.isEmpty { return marks }
        }
    }
}

private struct MarkRequest: Encodable {
    var kind: AlbumKind
    var id: Int
    var verdict: FeedbackMark.Verdict
}

private struct UnmarkRequest: Encodable {
    var kind: AlbumKind
    var id: Int
}

private struct MarksRequest: Encodable {
    var after: Int
}

struct MarkReply: Decodable {
    var feedback: FeedbackMark

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, feedback
    }

    init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        feedback = try container.decode(FeedbackMark.self, forKey: .feedback)
    }
}

struct UnmarkReply: Decodable {
    var removed: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, removed
    }

    init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        removed = try container.decode(Bool.self, forKey: .removed)
    }
}

struct MarksReply: Decodable {
    var feedback: [FeedbackMark]
    var more: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, feedback, more
    }

    init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        feedback = try container.decode([FeedbackMark].self, forKey: .feedback)
        more = try container.decode(Bool.self, forKey: .more)
    }
}
