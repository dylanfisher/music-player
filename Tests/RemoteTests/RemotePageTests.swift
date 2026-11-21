import Foundation
import JavaScriptCore
import Testing

@testable import Commands
@testable import Remote

private let folder = URL(fileURLWithPath: #filePath, isDirectory: false)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Support/Remote", isDirectory: true)

private func text(_ name: String) throws -> String {
    try String(contentsOf: folder.appendingPathComponent(name, isDirectory: false), encoding: .utf8)
}

/// logic.js in a context of its own, its exports as globals: JavaScriptCore runs scripts, not
/// modules, and the file keeps each export at the start of a top-level line so this holds.
private func logic() throws -> JSContext {
    let context = try #require(JSContext())
    var thrown: String?
    context.exceptionHandler = { _, exception in thrown = exception?.toString() }
    let script = try text("logic.js").split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("export ") ? String($0.dropFirst("export ".count)) : String($0) }
        .joined(separator: "\n")
    #expect(
        script.range(of: #"(?m)^\s+export\s"#, options: .regularExpression) == nil,
        "an export logic.js doesn't start a line with")
    context.evaluateScript(script)
    #expect(thrown == nil, "\(thrown ?? "")")
    return context
}

/// Runs `script` and gives its value as JSON, failing with any exception.
private func run(_ context: JSContext, _ script: String) -> String? {
    var thrown: String?
    context.exceptionHandler = { _, exception in thrown = exception?.toString() }
    let value = context.evaluateScript("JSON.stringify((() => { \(script) })())")
    #expect(thrown == nil, "\(thrown ?? "") in \(script)")
    return value?.toString()
}

@Test func theServedFilesAreExactlyThePagesFilesAndTheIconTheBundleMakes() throws {
    let listed = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect((listed + ["icon.png"]).sorted() == RemotePage.files.map(\.name).sorted())
    #expect(throws: PageMissing.self) { try RemotePage(folder: folder) }
    let page = RemotePage(contents: ["index.html": [1], "logic.js": [2]])
    #expect(page.reply("/index.html", ifNoneMatch: nil)?.body == [1])
    #expect(page.reply("/logic.js", ifNoneMatch: nil)?.body == [2])
    for path in ["/app.js", "/Logic.js", "/logic.js/", "/./logic.js", "//logic.js", "/../logic.js"]
    {
        #expect(page.reply(path, ifNoneMatch: nil) == nil, "\(path)")
    }
}

@Test func thePageSetsNoMarkupFromTheMacsAndRunsOnlyRemoteCommands() throws {
    let app = try text("app.js")
    for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval("] {
        #expect(!app.contains(sink), "\(sink)")
    }
    let remote = Set(AppCommands.all().filter(\.runsFromRemote).map(\.id.rawValue))
    let named = try NSRegularExpression(pattern: #""((?:playback|queue|receiver)\.[A-Za-z]+)""#)
    let found = named.matches(in: app, range: NSRange(app.startIndex..., in: app)).compactMap {
        Range($0.range(at: 1), in: app).map { String(app[$0]) }
    }
    #expect(found.count > 15)
    for id in found { #expect(remote.contains(id), "\(id)") }
}

/// app.js parses: its import taken out, it's compiled as a function's body without running.
@Test func thePagesScriptParses() throws {
    let context = try #require(JSContext())
    var thrown: String?
    context.exceptionHandler = { _, exception in thrown = exception?.toString() }
    let body = try text("app.js").replacingOccurrences(
        of: #"import \{[^}]*\} from "\./logic\.js";"#, with: "", options: .regularExpression)
    #expect(!body.contains("import "))
    context.setObject(body, forKeyedSubscript: "body" as NSString)
    context.evaluateScript("new Function(body)")
    #expect(thrown == nil, "\(thrown ?? "")")
}

@Test func thePagesLimitsAreTheServers() throws {
    let context = try logic()
    #expect(run(context, "return RANGE_SIZE") == "\(RemoteLibrary.rangeLimit)")
    #expect(run(context, "return TRACKS_PER_COMMAND") == "\(CommandArgument.maximumTracks)")
}

@Test func theMacChosenIsThePickedThenThePlayingThenTheLastControlledThenOwn() throws {
    let context = try logic()
    let macs = """
        const macs = [
          {id: "a", paired: true, state: "paused"},
          {id: "b", paired: true, state: "playing", lastPlayedAt: 10},
          {id: "c", paired: true, state: "playing", lastPlayedAt: 20},
          {id: "d", paired: false, state: null},
          {id: "e", paired: true, state: "playing"},
        ];
        """
    #expect(run(context, macs + "return chooseMac(macs, {picked: 'a'})") == #""a""#)
    #expect(run(context, macs + "return chooseMac(macs, {picked: 'd'})") == #""c""#)
    #expect(run(context, macs + "return chooseMac(macs, {})") == #""c""#)
    let stopped =
        "const macs = [{id: 'a', paired: true, state: 'stopped'},"
        + " {id: 'b', paired: true, state: 'paused'}, {id: 'c', paired: false, state: 'playing'}];"
    #expect(
        run(context, stopped + "return chooseMac(macs, {lastControlled: 'b', own: 'a'})") == #""b""#
    )
    #expect(
        run(context, stopped + "return chooseMac(macs, {lastControlled: 'c', own: 'a'})") == #""a""#
    )
    #expect(
        run(context, stopped + "return chooseMac(macs, {lastControlled: 'x', own: 'y'})") == #""a""#
    )
    #expect(run(context, "return chooseMac([{id: 'a', paired: false}], {own: 'a'})") == "null")
}

@Test func aTokenGoesOnlyToTheOriginItPairedAt() throws {
    let context = try logic()
    let instance = """
        const mac = {id: "m", host: "Den", addresses: ["192.168.1.9", "fe80::1"], port: 47800};
        """
    #expect(
        run(context, instance + "return instanceOrigins(mac)")
            == #"["http://den.local:47800","http://192.168.1.9:47800","http://[fe80::1]:47800"]"#)
    #expect(
        run(context, instance + "return reach(mac, {}, 'http://192.168.1.5:47800')")
            == #"{"origin":"http://192.168.1.9:47800","token":null}"#)
    #expect(
        run(context, instance + "return reach(mac, {}, 'http://studio.local:47800')")
            == #"{"origin":"http://den.local:47800","token":null}"#)
    let kept = "const tokens = {[tokenKey('m', 'http://den.local:47800')]: 't1'};"
    #expect(
        run(context, instance + kept + "return reach(mac, tokens, 'http://192.168.1.5:47800')")
            == #"{"origin":"http://den.local:47800","token":"t1"}"#)
    // Another advert claiming the ID at an address of its own gets no token.
    let impostor = "const fake = {id: 'm', host: 'evil', addresses: ['192.168.1.66'], port: 47800};"
    #expect(
        run(context, impostor + kept + "return reach(fake, tokens, 'http://192.168.1.5:47800')")
            == #"{"origin":"http://192.168.1.66:47800","token":null}"#)
}

@Test func aListFetchesTheRangesInViewAndOneEitherSideAndKeepsTwentyUsedLast() throws {
    let context = try logic()
    #expect(run(context, "return wantedRanges(0, 10, 1000)") == "[0,200]")
    #expect(run(context, "return wantedRanges(450, 470, 1000)") == "[200,400,600]")
    #expect(run(context, "return wantedRanges(390, 410, 1000)") == "[0,200,400,600]")
    #expect(run(context, "return wantedRanges(990, 999, 1000)") == "[600,800]")
    #expect(run(context, "return wantedRanges(0, 10, 0)") == "[]")
    #expect(run(context, "return wantedRanges(0, 30, 12)") == "[0]")
    #expect(
        run(context, "return [keepsArrival(400, [200, 400]), keepsArrival(0, [200])]")
            == "[true,false]")
    let cache = """
        const cache = new RangeCache();
        for (let start = 0; start < 20 * 200; start += 200) cache.put(start, [start]);
        cache.get(0);
        cache.put(4000, [4000]);
        """
    #expect(
        run(
            context,
            cache + "return [cache.has(0), cache.has(200), cache.starts.length, cache.starts[19]]")
            == "[true,false,20,4000]")
    #expect(run(context, "return CACHED_RANGES") == "20")
}

@Test func searchesSendOneAtATimeTheLatestWaitingAndOnlyTheLatestReplyShown() throws {
    let context = try logic()
    let script = """
        const queue = new SearchQueue();
        const sent = [queue.typed("a"), queue.typed("ab"), queue.typed("abc")];
        const first = queue.answered("a");
        const second = queue.answered("abc");
        const again = queue.typed("x");
        const failed = queue.answered("x");
        return [sent, first, second, again, failed];
        """
    #expect(
        run(context, script)
            == #"[["a",null,null],{"show":false,"next":"abc"},{"show":true,"next":null},"x",{"show":true,"next":null}]"#
    )
}

@Test func theEventParserGivesEachEventsDataAcrossChunksAndSkipsComments() throws {
    let context = try logic()
    let script = """
        const parser = new EventParser();
        return [parser.push("data: {\\"a\\""), parser.push(":1}\\n"), parser.push("\\n:\\n\\n"),
          parser.push("data: x\\r\\ndata:y\\r\\n\\r\\ndata: z\\n\\n")];
        """
    #expect(run(context, script) == #"[[],[],["{\"a\":1}"],["x\ny","z"]]"#)
}

@Test func theJumpBarsLettersOnlyMoveForward() throws {
    let context = try logic()
    #expect(
        run(
            context,
            "return letterOffsets(['10cc', 'ABBA', 'Air', 'Émilie', 'beck', 'Zed', 'Ångström'])")
            == ##"[["#",0],["A",1],["E",3],["Z",5]]"##)
    #expect(run(context, "return letterOffsets([])") == "[]")
}

@Test func thePositionAdvancesOnThePhonesClockAndTimesReadAsAClock() throws {
    let context = try logic()
    let state = "const s = {state: 'playing', positionSeconds: 10, track: {durationSeconds: 12}};"
    #expect(run(context, state + "return positionNow(s, 1000, 2500)") == "11.5")
    #expect(run(context, state + "return positionNow(s, 1000, 9000)") == "12")
    #expect(
        run(context, "return positionNow({state: 'paused', positionSeconds: 4}, 0, 9000)") == "4")
    #expect(run(context, "return positionNow({state: 'stopped'}, 0, 0)") == "null")
    #expect(
        run(context, "return [clock(187), clock(3723), clock(null), clock(0.4)]")
            == #"["3:07","1:02:03","–:––","0:00"]"#)
    #expect(run(context, "return [backoff(0), backoff(3), backoff(10)]") == "[1000,8000,30000]")
}

@Test func aTapPlaysThatTrackAndTheLoadedOnesAfterItUpToTheLimit() throws {
    let context = try logic()
    let rows = "const rows = [[1], [2], [null], [4], undefined, [6]];"
    #expect(run(context, rows + "return tracksFrom(1, 6, (i) => rows[i], 100)") == #""tracks:2,4""#)
    #expect(run(context, rows + "return tracksFrom(0, 6, (i) => rows[i], 2)") == #""tracks:1,2""#)
    #expect(run(context, rows + "return tracksFrom(4, 6, (i) => rows[i], 100)") == "null")
}
