import Foundation
import Testing

@testable import Library
@testable import Settings

private let clock = SyncClock(ms: 1_800_000_000_000, counter: 3)
private let playlist = String(repeating: "ab", count: 16)

private let everyEvent: [SyncEvent] = [
    .play(path: "music/a.flac", at: 1_700_000_000.25),
    .skip(path: "music/a.flac"),
    .counts(path: "music/a.flac", plays: 3, skips: 1, lastPlayed: nil),
    .counts(path: "music/a.flac", plays: 0, skips: 0, lastPlayed: 12.5),
    .rating(path: "music/Caf\u{e9} \"q\"\\b.flac", stars: 0),
    .loved(path: "music/line\nbreak.flac", loved: true),
    .added(path: "music/a.flac", at: 0),
    .move(from: "music/a.flac", to: "music/b/\u{1F3B5}.flac"),
    .playlistCreate(playlist: playlist, name: "Mix", rules: nil),
    .playlistCreate(
        playlist: playlist, name: "Smart", rules: try! SmartRules(match: .all, rules: []).json()),
    .playlistRename(playlist: playlist, name: "Mix \u{e9}"),
    .playlistRules(playlist: playlist, rules: try! SmartRules(match: .any, rules: []).json()),
    .playlistEntries(playlist: playlist, paths: ["music/a.flac", "music/b.flac"]),
    .playlistEntries(playlist: playlist, paths: []),
    .playlistDelete(playlist: playlist),
]

@Test func everyEventReadsBackAsWritten() throws {
    for (seq, event) in everyEvent.enumerated() {
        let record = SyncRecord(seq: Int64(seq + 1), clock: clock, event: event)
        #expect(!record.line.contains("\n"))
        #expect(try SyncRecord(line: Array(record.line.utf8)[...]) == record, "\(record.line)")
        // Foundation reads it as the same JSON, so other tools can too.
        #expect(
            try JSONSerialization.jsonObject(with: Data(record.line.utf8)) is [String: Any])
    }
}

private func problem(_ line: String) -> String? {
    do {
        _ = try SyncRecord(line: Array(line.utf8)[...])
        return nil
    } catch {
        return error.description
    }
}

@Test func everyLevelOfALineIsDecodedStrictly() {
    let head = #""seq":1,"ms":1,"n":0"#
    let refused: [(String, String)] = [
        ("", "ends early"),
        ("[]", "unexpected byte"),
        (#"{\#(head),"event":"skip","path":"a"} "#, "text after"),
        (#"{\#(head), "event":"skip","path":"a"}"#, "unexpected byte"),
        (#"{\#(head),"event":"skip"}"#, #"has no "path""#),
        (#"{\#(head),"event":"skip","path":"a","extra":1}"#, "unknown key"),
        (#"{\#(head),"event":"skip","path":"a","path":"b"}"#, "appears twice"),
        (#"{\#(head),"event":"jump","path":"a"}"#, "unknown event"),
        (#"{"seq":0,"ms":1,"n":0,"event":"skip","path":"a"}"#, "isn't in"),
        (#"{"seq":1.0,"ms":1,"n":0,"event":"skip","path":"a"}"#, "isn't an integer"),
        (#"{"seq":01,"ms":1,"n":0,"event":"skip","path":"a"}"#, "leading zero"),
        (#"{"seq":99999999999999999999,"ms":1,"n":0,"event":"skip","path":"a"}"#, "overflows"),
        (#"{"seq":1,"ms":1e999,"n":0,"event":"skip","path":"a"}"#, "isn't finite"),
        (#"{\#(head),"event":"skip","path":"/abs"}"#, "relative path"),
        (#"{\#(head),"event":"skip","path":"a/../b"}"#, "relative path"),
        (#"{\#(head),"event":"skip","path":"a//b"}"#, "relative path"),
        (#"{\#(head),"event":"skip","path":"a\u0000b"}"#, "relative path"),
        (#"{\#(head),"event":"skip","path":"\ud800"}"#, "lone surrogate"),
        (#"{\#(head),"event":"skip","path":1}"#, "isn't a string"),
        (#"{\#(head),"event":"play","path":"a","at":-1}"#, "isn't in"),
        (#"{\#(head),"event":"play","path":"a","at":"1"}"#, "isn't a number"),
        (#"{\#(head),"event":"rating","path":"a","stars":6}"#, "isn't in"),
        (#"{\#(head),"event":"loved","path":"a","loved":1}"#, "true or false"),
        (#"{\#(head),"event":"playlistDelete","playlist":"ABAB"}"#, "hex digits"),
        (
            #"{\#(head),"event":"playlistRename","playlist":"\#(playlist)","name":"a\nb"}"#,
            "control"
        ),
        (
            #"{\#(head),"event":"playlistRename","playlist":"\#(playlist)","name":"a\u202eb"}"#,
            "format"
        ),
        (#"{\#(head),"event":"playlistRules","playlist":"\#(playlist)","rules":"{}"}"#, "rules"),
        (
            #"{\#(head),"event":"playlistEntries","playlist":"\#(playlist)","paths":["a",1]}"#,
            "unexpected byte"
        ),
        (
            #"{\#(head),"event":"playlistEntries","playlist":"\#(playlist)","paths":"a"}"#,
            "list of strings"
        ),
        (
            #"{\#(head),"event":"playlistEntries","playlist":"\#(playlist)","paths":["/a"]}"#,
            "relative path"
        ),
    ]
    for (line, expected) in refused {
        let found = problem(line)
        #expect(found?.contains(expected) == true, "\(line): \(found ?? "accepted")")
    }
    // A raw byte that isn't UTF-8.
    var bytes = Array(#"{\#(head),"event":"skip","path":"a"#.utf8)
    bytes += [0xFF] + Array(#""}"#.utf8)
    #expect(throws: SyncLineProblem.notJSON("a string isn't UTF-8")) {
        try SyncRecord(line: bytes[...])
    }
}

@Test func aDecomposedPathIsReadPrecomposed() throws {
    let line = #"{"seq":1,"ms":1,"n":0,"event":"skip","path":"Cafe\#u{301}.flac"}"#
    #expect(try SyncRecord(line: Array(line.utf8)[...]).event == .skip(path: "Caf\u{e9}.flac"))
}

@Test func theClockTicksAndStaysWithinTheSkewBound() {
    let start = SyncClock(ms: 1000, counter: 0)
    #expect(SyncClock.next(after: start, wallMs: 2000).event == SyncClock(ms: 2000, counter: 0))
    #expect(SyncClock.next(after: start, wallMs: 500).event == SyncClock(ms: 1000, counter: 1))
    let far = SyncClock(ms: 1_000_000_000, counter: 7)
    let (event, state) = SyncClock.next(after: start, wallMs: 2000, field: far)
    #expect(event == SyncClock(ms: 1_000_000_000, counter: 8))
    #expect(state == SyncClock(ms: 2000 + SyncClock.skewBoundMs, counter: 0))
    // A wall clock set back more than the bound still gives later clocks.
    let ahead = SyncClock(ms: 10_000_000, counter: 4)
    let back = SyncClock.next(after: ahead, wallMs: 1000)
    #expect(back.event == SyncClock(ms: 10_000_000, counter: 5) && back.state == back.event)
    #expect(SyncClock.next(after: back.state, wallMs: 1000).event > back.event)
    let near = SyncClock(ms: 3000, counter: 0)
    #expect(
        SyncClock.next(after: start, wallMs: 2000, field: near) == (near.successor, near.successor))
}

private func lines(_ text: [UInt8], maximumLine: Int = 8) throws -> ([SyncLogLine], Int) {
    var reader = SyncLogLines(from: 0, end: text.count, maximumLine: maximumLine) {
        Array(text[$0])
    }
    var found: [SyncLogLine] = []
    while let line = try reader.next() { found.append(line) }
    return (found, reader.offset)
}

@Test func linesStopAtTheLastCompleteOneAndSkipTooLongOnes() throws {
    let text = Array("ab\n\(String(repeating: "x", count: 20))\ncd\nunfinished".utf8)
    let (found, offset) = try lines(text)
    #expect(found == [.line(Array("ab".utf8)), .tooLong(bytes: 20), .line(Array("cd".utf8))])
    #expect(offset == text.count - "unfinished".count)
}

@Test func linesSpanningChunksReadWhole() throws {
    let long = String(repeating: "y", count: SyncLogLines.chunkBytes + 10)
    let text = Array("a\n\(long)\nb\n".utf8)
    let (found, _) = try lines(text, maximumLine: SyncLogLines.chunkBytes * 2)
    #expect(found == [.line([0x61]), .line(Array(long.utf8)), .line([0x62])])
}

/// A folder with a machine's log holding `lines`.
private func folder(with lines: [String], name: String = String(repeating: "c", count: 32))
    throws -> (URL, LibraryIndex)
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sync-hostile-\(UUID().uuidString)")
    let sync = root.appendingPathComponent("sync")
    try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(
        to: sync.appendingPathComponent(name + ".log"))
    let index = try LibraryIndex(at: root.appendingPathComponent("library.sqlite"))
    index.wallClockMs = { clock.ms }
    _ = try index.locate(
        [WatchedFolder(path: "library", share: "smb://nas/music", kind: .network)],
        among: [MountedShare(url: "smb://nas/music", mountPoint: root.path + "/music")])
    return (sync, index)
}

@Test func problemsInALogAreCappedAndTheRestOfItIsRead() throws {
    let bad = (0..<150).map { "bad \($0)" }
    let good = SyncRecord(
        seq: 1, clock: clock, event: .play(path: "music/library/a.flac", at: 1_700_000_000)
    ).line
    let (sync, index) = try folder(with: bad + [good, good])
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.applied == 1)
    #expect(report.problems.count == SyncReport.maximumProblems + 1)
    #expect(report.problems.last?.hasSuffix("51 more problems") == true)
    // The repeated event is the 151st problem.
    let plays = try index.database.prepare("SELECT play_count FROM plays").map { try $0.int(0) }
    #expect(plays == [1])
    // Read again, nothing is applied or reported twice.
    let again = try index.sync(folder: "sync", at: sync.path)
    #expect(again.applied == 0 && again.problems.isEmpty)
}

@Test func onlyLogNamesAreReadAndALinkIsRefused() throws {
    let line = SyncRecord(
        seq: 1, clock: clock, event: .play(path: "music/library/a.flac", at: 1_700_000_000)
    ).line
    let (sync, index) = try folder(with: [line], name: "not-a-machine")
    let target = sync.appendingPathComponent("not-a-machine.log")
    try FileManager.default.createSymbolicLink(
        at: sync.appendingPathComponent(String(repeating: "d", count: 32) + ".log"),
        withDestinationURL: target)
    try FileManager.default.createDirectory(
        at: sync.appendingPathComponent(String(repeating: "e", count: 32) + ".log"),
        withIntermediateDirectories: false)
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.applied == 0)
    #expect(report.problems.count == 2, "\(report.problems)")
    #expect(report.problems.allSatisfy { $0.contains("isn't used") || $0.contains("can't open") })
}

@Test func aFolderThatIsALinkIsRefused() throws {
    let (sync, index) = try folder(with: [])
    let link = sync.deletingLastPathComponent().appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sync)
    #expect(throws: SyncFileError.self) { try index.sync(folder: "sync", at: link.path) }
}

@Test func theLogStopsAtItsCapAndSaysSoOnce() throws {
    let (sync, index) = try folder(with: [])
    try index.database.execute(
        "UPDATE sync_state SET log_bytes = \(SyncRecord.maximumLogBytes - 10)")
    let path = sync.deletingLastPathComponent().path + "/music/library/a.flac"
    try index.recordPlay(path, at: 1_700_000_000)
    try index.recordPlay(path, at: 1_700_000_001)
    #expect(
        try index.database.prepare("SELECT count(*) FROM sync_outbox").map { try $0.int(0) } == [0])
    #expect(try index.discards().count == 1)
}

@Test func aLogsTextIsEscapedInItsProblems() throws {
    let (sync, index) = try folder(with: [
        #"{"seq":1,"ms":1,"n":0,"event":"fake\nrow","path":"a"}"#,
        #"{"seq":2,"ms":1,"n":0,"event":"skip","path":"a","x\u000ay":1}"#,
    ])
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.count == 2)
    #expect(report.problems.allSatisfy { !$0.contains("\n") }, "\(report.problems)")
}

@Test func aMoveOntoItselfKeepsTheStats() throws {
    let play = SyncRecord(
        seq: 1, clock: clock, event: .play(path: "music/library/a.flac", at: 1_700_000_000)
    ).line
    let move = SyncRecord(
        seq: 2, clock: clock, event: .move(from: "music/library/a.flac", to: "music/library/a.flac")
    ).line
    let (sync, index) = try folder(with: [play, move])
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.count == 1)
    #expect(try index.database.prepare("SELECT play_count FROM plays").map { try $0.int(0) } == [1])
}

@Test func aLongKeyFromALogIsCutInItsProblem() {
    let long = String(repeating: "k", count: 100_000)
    for line in [
        #"{"seq":1,"ms":1,"n":0,"event":"skip","path":"a","\#(long)":1}"#,
        #"{"seq":1,"ms":1,"n":0,"event":"\#(long)","path":"a"}"#,
        #"{"\#(long)":1,"\#(long)":1}"#,
    ] {
        let found = problem(line)
        #expect(found.map { $0.count < 400 } == true, "\(found?.count ?? 0) characters")
    }
}

@Test func aLogThatShrinksMidReadStopsOnlyThatLog() throws {
    let lines = (1...20_000).map {
        SyncRecord(
            seq: Int64($0), clock: clock,
            event: .play(path: "music/library/a.flac", at: 1_700_000_000)
        ).line
    }
    let other = String(repeating: "f", count: 32)
    let (sync, index) = try folder(with: lines)
    let late = SyncRecord(
        seq: 1, clock: SyncClock(ms: clock.ms + 1, counter: 0),
        event: .skip(path: "music/library/b.flac")
    ).line
    try Data((late + "\n").utf8).write(to: sync.appendingPathComponent(syncLogName(other)))
    let shrinking = sync.appendingPathComponent(syncLogName(String(repeating: "c", count: 32)))
    var calls = 0
    index.wallClockMs = {
        calls += 1
        // Once the first chunk is read, the log is cut short under the reader.
        if calls == 3 { truncate(shrinking.path, 100) }
        return clock.ms
    }
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.contains { $0.contains("it got shorter") }, "\(report.problems)")
    #expect(report.applied > 1 && report.applied < lines.count + 1)
    let skips = try index.database.prepare("SELECT sum(skip_count) FROM plays").map {
        try $0.int(0)
    }
    #expect(skips == [1])
}
