import AppKit
import KeyChord
import Settings
import Testing

@testable import Fixtures
@testable import Palette

private func item(_ title: String, _ kind: PaletteItem.Kind = .artist) -> PaletteItem {
    PaletteItem(kind: kind, key: "\(kind):\(title)", title: title)
}

@Test func betterMatchesRankFirstAndOnlyTheBestAreKept() {
    let items = ["Pink Floyd", "Prince", "The Police", "Portishead"].map { item($0) }
    let ranked = rankPalette(items, query: "pf", frecency: [:], limit: 2)
    #expect(ranked.map(\.item.title) == ["Pink Floyd"])
    #expect(
        ranked[0].highlights == [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1)])
    #expect(rankPalette(items, query: "p", frecency: [:], limit: 2).count == 2)
}

@Test func tiesGoToTheKindThenFrecencyThenTheShorterTitle() {
    let items = [item("Abba", .album), item("Abba", .artist), item("Abbas")]
    #expect(rankPalette(items, query: "abba", frecency: [:], limit: 5).map(\.index) == [1, 0, 2])
    // Frecency 16 adds 4, enough to beat a tie but not a better match.
    let frecent = rankPalette(items, query: "abb", frecency: ["album:Abba": 16], limit: 5)
    #expect(frecent.first?.index == 0)
}

@Test func byKindListsEachKindsBestInTurn() {
    // Three artists would fill the limit, yet each kind keeps its own best, artists first.
    let items = [
        item("Abba Gold", .track), item("Abbas", .artist), item("Abba Live", .album),
        item("Abba", .track), item("Abba Teens", .artist), item("Abba Band", .artist),
    ]
    let ranked = rankPalette(items, query: "abba", frecency: [:], limit: 2, byKind: true)
    #expect(ranked.map(\.item.title) == ["Abbas", "Abba Band", "Abba Live", "Abba", "Abba Gold"])
    let empty = rankPalette(items, query: "", frecency: ["track:Abba": 16], limit: 2, byKind: true)
    #expect(empty.map(\.item.kind) == [.artist, .artist, .album, .track, .track])
    #expect(empty.last?.item.title == "Abba Gold")
}

@Test func anEmptyQueryListsTheMostFrecentFirst() {
    let items = ["A", "B", "C"].map { item($0) }
    let ranked = rankPalette(items, query: "", frecency: ["artist:C": 4], limit: 5)
    #expect(ranked.map(\.item.title) == ["C", "A", "B"])
}

@Test func anEmptyQueryListsOnlyTheKindsGiven() {
    let items = [item("Electronic", .genre), item("Play", .command), item("Mix", .playlist)]
    let frecency: [String: Double] = ["genre:Electronic": 16]
    let empty = rankPalette(
        items, query: "", frecency: frecency, limit: 5, emptyQueryKinds: [.command])
    #expect(empty.map(\.item.title) == ["Play"])
    // Typing finds every kind.
    let typed = rankPalette(
        items, query: "l", frecency: frecency, limit: 5, emptyQueryKinds: [.command])
    #expect(Set(typed.map(\.item.title)) == ["Electronic", "Play"])
}

@Test func frecencyWeighsRecentVisitsMore() {
    var frecency = Frecency(VisitLog(visits: []))
    frecency.record("artist:A", now: 0)
    frecency.record("artist:A", now: 0)
    frecency.record("artist:B", now: 0)
    #expect(frecency.scores(now: 60) == ["artist:A": 8, "artist:B": 4])
    #expect(frecency.scores(now: 7200)["artist:A"] == 4)
    #expect(frecency.scores(now: 200_000)["artist:A"] == 1)
    #expect(frecency.scores(now: 1_000_000)["artist:A"] == 0.5)
    #expect(frecency.log.problem() == nil)
    #expect(Frecency.bonus(1) == 0)
    #expect(Frecency.bonus(4) == 2)
    #expect(Frecency.bonus(100) == 4)
}

@Test func theLogKeepsItsCapacityByDroppingTheLeastFrecent() {
    var frecency = Frecency(
        VisitLog(
            visits: (0..<VisitLog.capacity).map {
                VisitLog.Visit(
                    key: String(format: "k%05d", $0), count: $0 == 0 ? 1 : 5, lastSeconds: 0)
            }))
    frecency.record("new", now: 0)
    #expect(frecency.log.visits.count == VisitLog.capacity)
    #expect(!frecency.log.visits.contains { $0.key == "k00000" })
    #expect(frecency.log.problem() == nil)
}

@MainActor @Test func theLatestQueryWins() async {
    let model = PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 })
    _ = model.open((0..<2000).map { item("Artist \($0)") } + [item("Zappa")], byKind: false)
    // `async let` children may start in either order under load, so the first query is begun
    // and seen to be ranking (it sets `query` before its first suspension) before the second.
    let first = Task { @MainActor in await model.setQuery("a") }
    let deadline = Date().addingTimeInterval(waitLimit)
    while model.query != "a" {
        guard Date() < deadline else {
            Issue.record("the first query never began: query is \"\(model.query)\"")
            return
        }
        await Task.yield()
    }
    await model.setQuery("zap")
    await first.value
    #expect(model.query == "zap")
    #expect(model.results.first?.item.title == "Zappa")
}

@MainActor @Test func aDraggedPlaceLandsOnAnyScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let size = NSSize(width: 640, height: 420)
    let centered = PaletteController.frame(size: size, on: screen, place: nil)
    #expect(centered.midX == screen.midX)
    #expect(centered.maxY == screen.maxY - screen.height / 5)
    let moved = NSRect(x: 0, y: 455, width: 640, height: 420)
    let place = PaletteController.place(of: moved, screens: [screen])
    #expect(place == PalettePlace(across: 0, down: 0))
    let small = NSRect(x: 0, y: 0, width: 1000, height: 600)
    #expect(PaletteController.frame(size: size, on: small, place: place).maxY == small.maxY)
    #expect(
        PaletteController.place(
            of: NSRect(x: 5000, y: 0, width: 640, height: 420), screens: [screen]) == nil)
}

@MainActor @Test func itemsAppendedBeforeTheFirstRankingAreKept() async {
    let model = PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 })
    let stale = model.open([item("Old")], byKind: false)
    let session = model.open([item("Abba", .command)], byKind: false)
    // An earlier open's items arrive late, and this one's before its ranking ran.
    async let late: Void = model.append([item("Old")], to: stale)
    async let more: Void = model.append([item("Queen")], to: session)
    async let first: Void = model.rank()
    _ = await (late, more, first)
    #expect(model.items.map(\.title) == ["Abba", "Queen"])
    #expect(model.results.map(\.item.title) == ["Abba", "Queen"])
}

@MainActor @Test func theSelectionStaysOnItsItemWhenItemsArrive() async throws {
    let palette = PaletteController(
        model: PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 }))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    // Go to Item, since ⌘K's empty query lists only commands.
    let session = palette.show(
        .goToItem, items: ["A", "B", "C"].map { item($0, .album) }, over: window, place: nil)
    palette.table.selectRowIndexes([1], byExtendingSelection: false)
    // Commands rank before albums, so these push "B" down a row.
    await palette.model.append([item("Play", .command)], to: session)
    #expect(palette.shown[palette.table.selectedRow].item.title == "B")
    // A new query selects its best match.
    await palette.model.setQuery("c")
    #expect(palette.table.selectedRow == 0)
    palette.close()
}

@MainActor @Test func commandsOpenListingOnlyCommandsOnTheFirstFrame() {
    var visits = Frecency(VisitLog(visits: []))
    visits.record("genre:Electronic", now: 0)
    let palette = PaletteController(model: PaletteModel(frecency: visits, now: { 0 }))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    palette.show(
        .commands, items: [item("Electronic", .genre), item("Play", .command)], over: window,
        place: nil)
    // Listed by the time `show` returns, with nothing awaited.
    #expect(palette.shown.map(\.item.title) == ["Play"])
    #expect(palette.table.numberOfRows == 1)
    #expect(palette.table.selectedRow == 0)
    palette.close()
}

@MainActor @Test func goToItemListsTheRowsItIsGivenOnTheFirstFrame() {
    let palette = PaletteController(
        model: PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 }))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    palette.show(
        .goToItem, items: [item("Song", .track), item("Abba")], over: window, place: nil)
    // ⌘P passes the rows it kept from the last open; they're listed with nothing awaited.
    #expect(palette.shown.map(\.item.title) == ["Abba", "Song"])
    #expect(palette.table.numberOfRows == 2)
    palette.close()
}

@MainActor @Test func commandReturnChoosesTheRowToFilterAndReturnToGoToIt() async throws {
    let palette = PaletteController(
        model: PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 }))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    var chosen: [(String, Bool)] = []
    palette.choose = { chosen.append(($0.title, $1)) }
    func open() async {
        palette.show(.goToItem, items: [item("Abba")], over: window, place: nil)
        while palette.shown.isEmpty { await Task.yield() }
    }
    await open()
    let commandReturn = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: palette.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    #expect(palette.takeKeyEquivalent(commandReturn))
    await open()
    palette.runSelected()
    #expect(chosen.map(\.0) == ["Abba", "Abba"])
    #expect(chosen.map(\.1) == [true, false])
}

@MainActor @Test func theFilterKeyFiltersToAnArtistOrAlbumWithTheCursorAtTheEnd() async throws {
    let palette = PaletteController(
        model: PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 }))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    var chosen: [(String, Bool)] = []
    palette.choose = { chosen.append(($0.title, $1)) }
    palette.filterChords = { [KeyChord(.right)] }
    let right = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
            windowNumber: palette.window.windowNumber, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
    palette.show(
        .goToItem, items: [item("Abba"), item("Abba Song", .track)], over: window, place: nil)
    while palette.shown.isEmpty { await Task.yield() }
    let editor = try #require(palette.field.currentEditor())
    editor.string = "ab"
    // → moves through the query until the cursor reaches its end.
    editor.selectedRange = NSRange(location: 0, length: 0)
    #expect(!palette.takeFilterKey(right))
    editor.selectedRange = NSRange(location: 2, length: 0)
    // On a track, → stays the field's.
    palette.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(palette.shown[1].item.kind == .track)
    #expect(!palette.takeFilterKey(right))
    palette.table.selectRowIndexes([0], byExtendingSelection: false)
    // An input method composing at the end keeps → for its composition.
    let textView = try #require(editor as? NSTextView)
    textView.setMarkedText(
        "か", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.hasMarkedText())
    #expect(!palette.takeFilterKey(right))
    textView.unmarkText()
    editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    #expect(palette.takeFilterKey(right))
    #expect(chosen.map(\.0) == ["Abba"])
    #expect(chosen.map(\.1) == [true])
    #expect(!palette.isShowing)
}

@MainActor @Test func theEdgeFollowsTheAppearanceAsItChanges() throws {
    let palette = PaletteController(
        model: PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 }))
    func alpha() throws -> CGFloat {
        try #require(palette.window.contentView?.layer?.borderColor?.alpha)
    }
    palette.window.appearance = NSAppearance(named: .darkAqua)
    #expect(try alpha() == 0.2)
    palette.window.appearance = NSAppearance(named: .aqua)
    #expect(try alpha() == 0.6)
}

// simple-spotlight's width, field and radius, read from its `SearchPanel`: 680 wide, a 56-point
// field in 24-point light type, radius 16. The palette's first height, 420, and its eleven
// 32-point rows, under a 1-point line.
@MainActor @Test func thePanelHasItsSize() async throws {
    let palette = PaletteController(
        model: PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 }))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    palette.show(
        .goToItem, items: (0..<20).map { item("Artist \($0)") }, over: window, place: nil)
    while palette.shown.isEmpty { await Task.yield() }
    palette.window.layoutIfNeeded()
    #expect(palette.window.frame.size == NSSize(width: 680, height: 420))
    #expect(palette.field.font == .systemFont(ofSize: 24, weight: .light))
    #expect(palette.window.contentView?.layer?.cornerRadius == 16)
    // The panel's material: Liquid Glass with the same radius from macOS 26, the popover
    // material before (ADR 0150).
    let material = try #require(palette.window.contentView?.subviews.first)
    if #available(macOS 26, *) {
        let glass = try #require(material as? NSGlassEffectView)
        #expect(glass.cornerRadius == 16)
    } else {
        #expect((material as? NSVisualEffectView)?.material == .popover)
    }
    #expect(palette.table.rect(ofRow: 0).height == 32)
    let scroll = try #require(palette.table.enclosingScrollView)
    // Eleven whole rows show, 5.5 points from the line and the bottom.
    let visible = scroll.documentVisibleRect
    #expect(palette.table.rect(ofRow: 0).minY - visible.minY == 5.5)
    #expect(visible.maxY - palette.table.rect(ofRow: 10).maxY == 5.5)
    // The selection is the focused selection color, as Searcher's, not the bright accent color.
    #expect(PaletteRowView.selectionColor == .selectedContentBackgroundColor)
    let row = try #require(palette.table.rowView(atRow: 0, makeIfNecessary: true))
    #expect(row.isSelected && row.interiorBackgroundStyle == .emphasized)
    palette.close()
}

/// Types `text` into the palette's field as the user would, replacing what's selected.
@MainActor
private func type(_ text: String, into palette: PaletteController) throws {
    let editor = try #require(palette.field.currentEditor() as? NSTextView)
    editor.insertText(text, replacementRange: editor.selectedRange())
}

/// Waits a few seconds for `condition`, yielding to the ranking task meanwhile.
@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(waitLimit)
    while !condition() {
        try #require(Date() < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// ⌘K opens with its last query selected, so typing replaces it and Return runs it again; ⌘K
/// while it has one clears it, and closes it once empty (53.14).
@MainActor @Test func thePaletteKeepsItsQueryUntilItsChordClearsIt() async throws {
    let palette = PaletteController(
        model: PaletteModel(frecency: Frecency(VisitLog(visits: [])), now: { 0 }))
    palette.closingChords = { $0 == .commands ? [KeyChord("k", .command)] : [] }
    var chosen: [String] = []
    palette.choose = { item, _ in chosen.append(item.title) }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    let items = ["Play", "Pause", "Stop"].map { item($0, .command) }
    func open() { palette.show(.commands, items: items, over: window, place: nil) }
    open()
    // With nothing typed it opens empty, listing every command at once.
    #expect(palette.field.stringValue.isEmpty)
    #expect(palette.shown.count == 3)
    try type("sto", into: palette)
    try await waitFor { palette.shown.map(\.item.title) == ["Stop"] }
    palette.runSelected()
    #expect(chosen == ["Stop"])
    #expect(!palette.isShowing)

    open()
    #expect(palette.field.stringValue == "sto")
    #expect(palette.model.query == "sto")
    #expect(palette.shown.map(\.item.title) == ["Stop"])
    let editor = try #require(palette.field.currentEditor())
    #expect(editor.selectedRange == NSRange(location: 0, length: 3))
    palette.runSelected()
    #expect(chosen == ["Stop", "Stop"])

    open()
    try type("pau", into: palette)
    #expect(palette.field.stringValue == "pau")
    try await waitFor { palette.shown.map(\.item.title) == ["Pause"] }
    let commandK = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: palette.window.windowNumber, context: nil, characters: "k",
            charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
    #expect(palette.takeKeyEquivalent(commandK))
    #expect(palette.isShowing)
    #expect(palette.field.stringValue.isEmpty)
    try await waitFor { palette.shown.count == 3 }
    #expect(palette.takeKeyEquivalent(commandK))
    #expect(!palette.isShowing)
    open()
    #expect(palette.field.stringValue.isEmpty)
    palette.close()
}

@Test func aKindAndAColonListOnlyThatKind() {
    let items = [
        item("Dream Baby Dream", .track), item("Dream", .artist), item("Dreamland", .album),
        item("Windowlicker", .track), item("Windowlicker", .album),
    ]
    let albums = rankPalette(items, query: "album: dream", frecency: [:], limit: 5)
    #expect(albums.map(\.item.title) == ["Dreamland"])
    #expect(albums[0].highlights == [NSRange(location: 0, length: 5)])
    let tracks = rankPalette(items, query: "T:windowlicker", frecency: [:], limit: 5)
    #expect(tracks.map(\.item.kind) == [.track])
    #expect(
        rankPalette(items, query: "track: dream", frecency: [:], limit: 5).map(\.item.title)
            == ["Dream Baby Dream"])
    // With nothing after the colon, every item of the kind.
    #expect(
        rankPalette(items, query: "artist:", frecency: [:], limit: 5, emptyQueryKinds: [.track])
            .map(\.item.title) == ["Dream"])
    // A word that isn't a kind's is part of the query.
    #expect(PaletteQuery("re: dream").kind == nil)
    #expect(PaletteQuery("re: dream").text == "re: dream")
}

/// Each library kind has a short prefix beside its name; "song" is no longer one (ADR 0161).
@Test func theShortPrefixesNameTheirKinds() {
    let short: [(String, PaletteItem.Kind)] = [
        ("a", .album), ("ar", .artist), ("t", .track), ("p", .playlist), ("g", .genre),
    ]
    for (prefix, kind) in short {
        #expect(PaletteQuery("\(prefix): dream").kind == kind)
        #expect(PaletteQuery("\(prefix.uppercased()):dream").text == "dream")
    }
    for kind in [PaletteItem.Kind.command, .setting, .output] {
        #expect(kind.shortName == nil)
    }
    #expect(PaletteQuery("song: dream").kind == nil)
    #expect(PaletteQuery("song: dream").text == "song: dream")
    #expect(PaletteItem.Kind.track.queryPrefixes == "track: or t:")
}
