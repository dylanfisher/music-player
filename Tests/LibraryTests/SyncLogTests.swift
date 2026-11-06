import Foundation
import Testing

@testable import Library
@testable import Settings

private let clock = SyncClock(ms: 1_800_000_000_000, counter: 3)
private let playlist = String(repeating: "ab", count: 16)

private let everyEvent: [SyncEvent] = [
    .play(path: "music/a.flac", at: 1_700_000_000.25),
    .skip(path: "music/a.flac"),
    .totals(path: "music/a.flac", player: .swinsian, plays: 3, skips: 1, lastPlayed: nil),
    .totals(path: "music/a.flac", player: .iTunes, plays: 0, skips: 0, lastPlayed: 12.5),
    .rating(path: "music/Caf\u{e9} \"q\"\\b.flac", stars: 0),
    .loved(path: "music/line\nbreak.flac", loved: true),
    .disliked(path: "music/a.flac"),
    .added(path: "music/a.flac", at: 0),
    .addedFiles(folder: "music/b", names: ["1.flac", "Caf\u{e9} \"q\".flac"], at: 1_700_000_000.5),
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
        (#"{\#(head),"event":"addedFiles","folder":"m","names":[],"at":1}"#, "no names"),
        (#"{\#(head),"event":"addedFiles","folder":"m","names":["a/b"],"at":1}"#, "with a /"),
        (#"{\#(head),"event":"addedFiles","folder":"m","names":[".."],"at":1}"#, "relative"),
        (#"{\#(head),"event":"addedFiles","folder":"/m","names":["a"],"at":1}"#, "relative"),
        (#"{\#(head),"event":"addedFiles","folder":"m","names":["a"]}"#, #"has no "at""#),
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

@Test func anEventForAPlaylistNeverCreatedWaitsTenSyncsThenIsSkipped() throws {
    let rename = SyncRecord(
        seq: 1, clock: clock, event: .playlistRename(playlist: playlist, name: "Mix")
    ).line
    let play = SyncRecord(
        seq: 2, clock: clock, event: .play(path: "music/library/a.flac", at: 1_700_000_000)
    ).line
    let (sync, index) = try folder(with: [rename, play])
    let plays = { try index.database.prepare("SELECT count(*) FROM plays").map { try $0.int(0) } }
    for _ in 0..<LibraryIndex.maximumWaitingSyncs {
        #expect(try index.sync(folder: "sync", at: sync.path).applied == 0)
    }
    #expect(try plays() == [0])
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.contains { $0.contains("which no log created in 10 syncs") })
    #expect(try plays() == [1])
}

@Test func aSyncAddsOnlySoManyPathsAndTheRestWait() throws {
    let lines = (1...30).map {
        SyncRecord(
            seq: Int64($0), clock: clock,
            event: .play(path: "music/library/\($0).flac", at: 1_700_000_000)
        ).line
    }
    let (sync, index) = try folder(with: lines)
    index.maximumNewPathsPerSync = 10
    let first = try index.sync(folder: "sync", at: sync.path)
    #expect(first.applied == 10)
    #expect(first.problems.contains { $0.contains("the most one does") })
    #expect(try index.sync(folder: "sync", at: sync.path).applied == 10)
}

@Test func aPlaylistEventListsOnlySoManyEntries() {
    let paths = Array(repeating: "a", count: SyncRecord.maximumEntries + 1)
    let line = SyncRecord(
        seq: 1, clock: clock, event: .playlistEntries(playlist: playlist, paths: paths)
    ).line
    #expect(problem(line)?.contains("lists over") == true)
}

private func record(_ seq: Int64, _ event: SyncEvent) -> String {
    SyncRecord(seq: seq, clock: SyncClock(ms: clock.ms + seq, counter: 0), event: event).line
}

@Test func anImportsCountsInAnEarlierBuildsShapeAreSkippedWithoutAProblem() throws {
    let (sync, index) = try folder(with: [
        #"{"seq":1,"ms":1800000000001,"n":0,"event":"counts","path":"music/library/a.flac","player":"swinsian","plays":5,"skips":0,"lastPlayed":null}"#,
        record(
            2,
            .totals(
                path: "music/library/a.flac", player: .swinsian, plays: 3, skips: 0,
                lastPlayed: nil)),
    ])
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.isEmpty, "\(report.problems)")
    #expect(report.applied == 1)
    let plays = try index.database.prepare("SELECT play_count FROM plays").map { try $0.int(0) }
    #expect(plays == [3])
}

@Test func movesReadOutOfOrderAndLatePlaysFollowTheChain() throws {
    let (sync, index) = try folder(with: [
        record(1, .move(from: "music/library/b.flac", to: "music/library/c.flac")),
        record(2, .move(from: "music/library/a.flac", to: "music/library/b.flac")),
        record(3, .play(path: "music/library/a.flac", at: 1_700_000_100)),
    ])
    let root = sync.deletingLastPathComponent().path + "/music/library/"
    try index.recordPlay(root + "a.flac", at: 1_700_000_000)
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.isEmpty, "\(report.problems)")
    let rows = try index.database.prepare(
        "SELECT p.path, s.play_count FROM paths p JOIN plays s ON s.path_id = p.id"
    ).map { (try $0.text(0), try $0.int(1)) }
    #expect(rows.map(\.0) == [root + "c.flac"])
    #expect(rows.map(\.1) == [2])
}

@Test func aMoveOntoAPlayedPathKeepsItsPlaysInHistory() throws {
    let (sync, index) = try folder(with: [
        record(1, .move(from: "music/library/a.flac", to: "music/library/b.flac"))
    ])
    let root = sync.deletingLastPathComponent().path + "/music/library/"
    try index.recordSkip(root + "a.flac")
    try index.recordPlay(root + "b.flac", at: 1_700_000_000)
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.isEmpty, "\(report.problems)")
    let recorded = try index.database.prepare(
        "SELECT pa.path FROM \(recordedTable) r JOIN paths pa ON pa.id = r.path_id"
    ).map { try $0.text(0) }
    #expect(recorded == [root + "b.flac"])
}

@Test func aMoveOntoAnImportedPathCountsEachPlayersImportOnce() throws {
    let totals = { (name: String, plays: Int, skips: Int) in
        SyncEvent.totals(
            path: "music/library/" + name, player: .swinsian, plays: plays, skips: skips,
            lastPlayed: nil)
    }
    let (sync, index) = try folder(with: [
        record(1, totals("a.flac", 5, 1)),
        record(2, totals("b.flac", 3, 2)),
        record(3, .move(from: "music/library/a.flac", to: "music/library/b.flac")),
    ])
    let root = sync.deletingLastPathComponent().path + "/music/library/"
    try index.recordPlay(root + "b.flac", at: 1_700_000_000)
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.isEmpty, "\(report.problems)")
    let counts = try index.database.prepare(
        "SELECT p.path, s.play_count, s.skip_count FROM paths p JOIN plays s ON s.path_id = p.id"
    ).map { [try $0.text(0), String(try $0.int(1)), String(try $0.int(2))] }
    #expect(counts == [[root + "b.flac", "6", "2"]])
    let imported = try index.database.prepare(
        "SELECT player, play_count, skip_count FROM \(importedPlaysTable)"
    ).map { [try $0.text(0), String(try $0.int(1)), String(try $0.int(2))] }
    #expect(imported == [["swinsian", "5", "2"]])
}

@Test func aMoveCantTakeTheRowOfAFileThisMacStillHas() throws {
    let (sync, index) = try folder(with: [
        record(1, .move(from: "music/library/a.flac", to: "music/library/b.flac"))
    ])
    let path = sync.deletingLastPathComponent().path + "/music/library/a.flac"
    try index.store([Crafted(path: path).scanned])
    let report = try index.sync(folder: "sync", at: sync.path)
    #expect(report.problems.contains { $0.contains("waits for its own scan") })
    #expect(try index.track(path: path) != nil)
}

@Test func anAddedFilesEventListsOnlySoManyNames() {
    let names = (0...SyncRecord.maximumAddedNames).map { "\($0).flac" }
    let line =
        SyncRecord(
            seq: 1, clock: clock, event: .addedFiles(folder: "music", names: names, at: 1)
        ).line
    #expect(problem(line)?.contains("over \(SyncRecord.maximumAddedNames)") == true)
}
