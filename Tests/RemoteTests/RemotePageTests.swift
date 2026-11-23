import Foundation
import JavaScriptCore
import Settings
import Testing

@testable import Commands
@testable import Remote

private let folder = URL(fileURLWithPath: #filePath, isDirectory: false)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Support/Remote", isDirectory: true)

private func text(_ name: String) throws -> String {
    try String(contentsOf: folder.appendingPathComponent(name, isDirectory: false), encoding: .utf8)
}

/// logic.js, or another of the page's modules, in a context of its own, its exports as globals:
/// JavaScriptCore runs scripts, not modules, and the file keeps each export at the start of a
/// top-level line so this holds.
private func logic(_ name: String = "logic.js") throws -> JSContext {
    let context = try #require(JSContext())
    var thrown: String?
    context.exceptionHandler = { _, exception in thrown = exception?.toString() }
    let script = try text(name).split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("export ") ? String($0.dropFirst("export ".count)) : String($0) }
        .joined(separator: "\n")
    #expect(
        script.range(of: #"(?m)^\s+export\s"#, options: .regularExpression) == nil,
        "an export \(name) doesn't start a line with")
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

/// app.js parses: its imports taken out, it's compiled as a function's body without running.
@Test func thePagesScriptParses() throws {
    let context = try #require(JSContext())
    var thrown: String?
    context.exceptionHandler = { _, exception in thrown = exception?.toString() }
    let body = try text("app.js").replacingOccurrences(
        of: #"import \{[^}]*\} from "\./[a-z]+\.js";"#, with: "", options: .regularExpression)
    #expect(!body.contains("import "))
    context.setObject(body, forKeyedSubscript: "body" as NSString)
    context.evaluateScript("new Function(body)")
    #expect(thrown == nil, "\(thrown ?? "")")
}

@Test func thePagesLimitsAreTheServers() throws {
    let context = try logic()
    #expect(run(context, "return RANGE_SIZE") == "\(RemoteLibrary.rangeLimit)")
}

@Test func theMacChosenIsThePickedThenThePlayingThenTheLastControlledThenOwn() throws {
    let context = try logic()
    let macs = """
        const macs = [
          {id: "a", paired: true, state: "paused"},
          {id: "b", paired: true, state: "playing", playedAgo: 20},
          {id: "c", paired: true, state: "playing", playedAgo: 10},
          {id: "d", paired: false, state: null},
          {id: "e", paired: true, state: "playing", playedAgo: null},
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

/// Two Macs whose clocks differ: the one whose own clock says it started more recently wins,
/// whatever their raw times say.
@Test func macsAreComparedByHowLongAgoEachStartedOnItsOwnClock() throws {
    let context = try logic()
    let script = """
        // Fast's clock runs 100 s ahead: its later lastPlayedAt is the older start.
        const fast = {now: 1100, lastPlayedAt: 1050};
        const slow = {now: 1000, lastPlayedAt: 990};
        const macs = [
          {id: "fast", paired: true, state: "playing", playedAgo: startedAgo(fast, 0, 2000)},
          {id: "slow", paired: true, state: "playing", playedAgo: startedAgo(slow, 1000, 2000)},
        ];
        return [macs[0].playedAgo, macs[1].playedAgo, chooseMac(macs, {}),
          startedAgo({now: 5}, 0, 0), startedAgo(null, 0, 0)];
        """
    #expect(run(context, script) == #"[52,11,"slow",null,null]"#)
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

@Test func aListFetchesAtMostThreeRangesAndAbortsThoseNoLongerWanted() throws {
    let context = try logic()
    let cached = "const cached = (start) => start === 200;"
    #expect(
        run(context, cached + "return planFetches([0, 200, 400, 600, 800], cached, [])")
            == #"{"start":[0,400,600],"abort":[]}"#)
    #expect(
        run(context, cached + "return planFetches([400, 600], cached, [0, 400])")
            == #"{"start":[600],"abort":[0]}"#)
    #expect(
        run(context, cached + "return planFetches([1000, 1200, 1400], cached, [1000, 1200, 1400])")
            == #"{"start":[],"abort":[]}"#)
    #expect(run(context, "return [RANGES_IN_FLIGHT, SETTLE_MS]") == "[3,100]")
}

@Test func aPageFromAnotherTagOrLengthMeansTheListChanged() throws {
    let context = try logic()
    let held = "const held = {stamp: 's1', total: 10};"
    #expect(
        run(
            context,
            held + """
                return [listChanged(null, {stamp: 's2', total: 3}),
                  listChanged(held, {stamp: 's1', total: 10}),
                  listChanged(held, {stamp: 's2', total: 10}),
                  listChanged(held, {stamp: 's1', total: 11})];
                """) == "[false,false,true,true]")
}

@Test func aStreamIsDeadAfterFortySilentSecondsAndBacksOffUntilItStaysUp() throws {
    let context = try logic()
    #expect(run(context, "return [isSilent(0, 40000), isSilent(0, 40001)]") == "[false,true]")
    // One that drops at once keeps counting; one up 30 s starts over.
    #expect(
        run(
            context,
            "return [failuresAfter(0, 0), failuresAfter(3, 29999), failuresAfter(3, 30000)]")
            == "[1,4,1]")
}

@Test func playListNamesTheListAsTheTracksReadDoesAndTheTrackToPlayFrom() throws {
    let context = try logic()
    #expect(
        run(context, "return playListArgument({sort: 'album', artist: 7}, 12)")
            == #""artist=7&sort=album&playFrom=12""#)
    #expect(
        run(context, "return playListArgument({q: 'a&b c', sort: 'artist'}, 3)")
            == #""q=a%26b%20c&sort=artist&playFrom=3""#)
}

@Test func browseStaysOnItsMacWhenThePageSwitchesByItself() throws {
    let context = try logic()
    #expect(
        run(
            context,
            """
            return [libraryMac("a", "b", "auto", ["a", "b"], false), libraryMac("a", "b", "picked", ["a", "b"], false),
              libraryMac("a", "b", "top", ["a", "b"], false), libraryMac(null, "b", "auto", ["a", "b"], false)];
            """) == #"["a","b","b","b"]"#)
}

@Test func browseLeavesAMacThatIsNoLongerPairedAndFollowsWhileUntouched() throws {
    let context = try logic()
    #expect(
        run(
            context,
            """
            return [libraryMac("a", "b", "auto", ["b"], false), libraryMac("a", "b", "auto", ["a", "b"], true)];
            """) == #"["b","b"]"#)
}

@Test func aRefusedQueueEditReadsTheQueueAgain() throws {
    let context = try logic()
    #expect(
        run(context, "return [afterQueueEdit(true), afterQueueEdit(false)]")
            == #"["wait","reload"]"#)
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
    // A `\r` ending a chunk waits to see whether `\n` follows, so `\r\n` split across
    // chunks is one line end, not a line and then a blank one that ends the event.
    let split = """
        const parser = new EventParser();
        return [parser.push("data: a\\r"), parser.push("\\ndata: b\\r"), parser.push("\\n\\r"),
          parser.push("\\n")];
        """
    #expect(run(context, split) == #"[[],[],[],["a\nb"]]"#)
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

/// Each icon is path data only, so the file can draw nothing but a shape, and the names the
/// page asks for are the icons it has, each on a button that says what it does.
@Test func theIconsArePathDataAndEachOneThePageNamesIsThere() throws {
    let context = try logic("icons.js")
    let names = try #require(run(context, "return Object.keys(ICONS)"))
    #expect(
        run(
            context, "return Object.values(ICONS).every((d) => /^[MLHVCSQTAZ0-9.,\\- ]+$/i.test(d))"
        ) == "true")
    let page = try text("index.html")
    let app = try text("app.js")
    // The names in `data-icon`, and on app.js's lines that draw one, each name `icon(` takes
    // or a choice of two gives.
    let named = try NSRegularExpression(pattern: #"(?:data-icon=|icon\(|\? |: )"([A-Za-z]+)""#)
    let drawing = app.split(separator: "\n").filter { $0.contains("icon(") || $0.contains("Icon(") }
    var used = Set<String>()
    for source in [page] + drawing.map(String.init) {
        for match in named.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            used.insert(String(source[Range(match.range(at: 1), in: source)!]))
        }
    }
    #expect(used.count == 11)
    for name in used { #expect(names.contains("\"\(name)\""), "\(name)") }
    let keys = try #require(
        try JSONSerialization.jsonObject(with: Data(names.utf8)) as? [String])
    #expect(Set(keys) == used, "an icon the page doesn't use")
    let buttons = try NSRegularExpression(pattern: #"<button[^>]*data-icon=[^>]*>"#)
    for match in buttons.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
        let tag = String(page[Range(match.range, in: page)!])
        #expect(tag.contains("aria-label="), "\(tag)")
    }
}

/// The search field names the short prefix of each kind the search lists, which the server
/// reads (ADR 0220).
/// Now Playing reads an album once: two tracks of it share a key, and another album, another
/// Mac or a track without one doesn't (ADR 0220).
@Test func nowPlayingsAlbumIsKeyedByMacAndAlbum() throws {
    let context = try logic()
    #expect(
        run(
            context,
            "const o = 'http://den.local:47800';"
                + " return [nowAlbumKey('m', o, { id: 1, albumID: 7 })"
                + " === nowAlbumKey('m', o, { id: 2, albumID: 7 }),"
                + " nowAlbumKey('m', o, { id: 1, albumID: 7 }) === nowAlbumKey('m', o, { id: 3, albumID: 8 }),"
                + " nowAlbumKey('m', o, { id: 1, albumID: 7 }) === nowAlbumKey('n', o, { id: 1, albumID: 7 }),"
                + " nowAlbumKey('m', o, { id: 1, albumID: null }), nowAlbumKey('m', o, null)]"
        ) == "[true,false,false,null,null]")
}

@Test func theSearchFieldNamesThePrefixes() throws {
    let page = try text("index.html")
    let field = try #require(page.split(separator: "\n").first { $0.contains("id=\"search\"") })
    for kind in [SearchKind.artist, .album, .track] {
        #expect(field.contains(" \(kind.shortName):"), "\(kind)")
    }
}

@Test func theScrubberHalvesItsSpeedAtEachStepLeftOfItsStrip() throws {
    let context = try logic()
    #expect(run(context, "return SCRUB_STEPS_PX") == "[32,96,160]")
    #expect(
        run(context, "return [-10, 0, 31, 32, 95, 96, 159, 160, 400].map(scrubSpeed)")
            == "[1,1,1,0.5,0.5,0.25,0.25,0.125,0.125]")
    // A strip 400 px tall: 100 px on it is a quarter of the list, and an eighth of that far left.
    #expect(
        run(
            context,
            "return [scrubbed(0.5, 100, 400, 0), scrubbed(0.5, -100, 400, 200),"
                + " scrubbed(0.9, 100, 400, 0), scrubbed(0.1, -100, 400, 0), scrubbed(0.3, 50, 0, 0)]"
        )
            == "[0.75,0.46875,1,0,0.3]")
}
