import AppKit
import Settings
import Testing

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

@Test func anEmptyQueryListsTheMostFrecentFirst() {
    let items = ["A", "B", "C"].map { item($0) }
    let ranked = rankPalette(items, query: "", frecency: ["artist:C": 4], limit: 5)
    #expect(ranked.map(\.item.title) == ["C", "A", "B"])
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
    _ = model.open((0..<2000).map { item("Artist \($0)") } + [item("Zappa")])
    async let first: Void = model.setQuery("a")
    async let second: Void = model.setQuery("zap")
    _ = await (first, second)
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
    let stale = model.open([item("Old")])
    let session = model.open([item("Abba", .command)])
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
    let session = palette.show(
        .commands, items: ["A", "B", "C"].map { item($0, .album) }, over: window, place: nil)
    // The ranking `show` started.
    while palette.shown.isEmpty { await Task.yield() }
    palette.table.selectRowIndexes([1], byExtendingSelection: false)
    // Commands rank before albums, so these push "B" down a row.
    await palette.model.append([item("Play", .command)], to: session)
    #expect(palette.shown[palette.table.selectedRow].item.title == "B")
    // A new query selects its best match.
    await palette.model.setQuery("c")
    #expect(palette.table.selectedRow == 0)
    palette.close()
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
