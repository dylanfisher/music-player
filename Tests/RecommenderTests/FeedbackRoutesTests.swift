import Foundation
import Testing

@testable import Recommender

@Test func marksSendTheirKindIdAndVerdict() async throws {
    let stub = try await StubService([
        (200, try fixture("feedback.json")), (200, try fixture("feedback-undo.json")),
    ])
    defer { stub.stop() }
    let client = try stub.client
    #expect(
        try await client.mark(.release, 4242, verdict: .notInterested)
            == FeedbackMark(
                seq: 7, kind: .release, id: 4242, verdict: .notInterested, at: 1_794_060_000))
    #expect(try await client.unmark(.master, 17))
    #expect(
        stub.requests.map(\.bodyText) == [
            #"{"id":4242,"kind":"release","verdict":"not_interested"}"#,
            #"{"id":17,"kind":"master"}"#,
        ])
    #expect(
        stub.requests.map { $0.head.prefix(while: { $0 != "\r\n" }) } == [
            "POST /v1/feedback HTTP/1.1", "POST /v1/feedback/undo HTTP/1.1",
        ])
}

@Test func theMarksAreReadPageByPageUntilThereAreNoMore() async throws {
    let first =
        #"{"ok": true, "feedback": [{"seq": 3, "kind": "master", "id": 17, "verdict": "already_have", "at": 1}], "more": true}"#
    let stub = try await StubService([(200, first), (200, try fixture("feedback-list.json"))])
    defer { stub.stop() }
    let marks = try await stub.client.marks()
    #expect(marks.map(\.seq) == [3, 7])
    #expect(marks.first?.verdict == .alreadyHave)
    #expect(stub.requests.map(\.bodyText) == [#"{"after":0}"#, #"{"after":3}"#])
}

@Test func aMarkReplyNotInTheContractFailsNamingTheField() {
    let cases: [(String, any Decodable.Type, String)] = [
        (
            #"{"ok": true, "feedback": {"seq": 7, "kind": "release", "id": 4242, "verdict": "loved", "at": 1}}"#,
            MarkReply.self, "feedback.verdict"
        ),
        (#"{"ok": true}"#, UnmarkReply.self, "removed"),
        (
            #"{"ok": true, "feedback": [{"seq": 7, "kind": "label", "id": 1, "verdict": "already_have", "at": 1}], "more": false}"#,
            MarksReply.self, "feedback.0.kind"
        ),
    ]
    for (reply, type, field) in cases {
        do throws(RecommenderError.Kind) {
            _ = try decodeReply(Array(reply.utf8), as: type)
            Issue.record("\(reply) decoded")
        } catch {
            guard case .unreadable(let why) = error else {
                Issue.record("\(field) gave \(error)")
                continue
            }
            #expect(why.contains(field), "\(why)")
        }
    }
}
