import AppKit
import DisplayText
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor @Test func aStatsReadThatEndsAfterANewerOneIsDropped() async throws {
    var pending: [(StatsPeriod, CheckedContinuation<StatsReport, any Error>)] = []
    let model = StatsModel { period in
        try await withCheckedThrowingContinuation { pending.append((period, $0)) }
    }
    let first = Task { await model.show(.all) }
    try await waitFor("the first read") { pending.count == 1 }
    let second = Task { await model.show(.week) }
    try await waitFor("the second read") { pending.count == 2 }
    #expect(model.isLoading)
    #expect(model.period == .week)
    var week = StatsReport(
        PeriodScan(
            span: nil, paths: [], buckets: [], bucketSeconds: 3600, libraryTracks: 1,
            undatedPlays: 0), firstPlays: FirstPlays(), calendar: .current)
    week.plays = 7
    pending[1].1.resume(returning: week)
    await second.value
    var all = week
    all.plays = 99
    pending[0].1.resume(returning: all)
    await first.value
    #expect(model.report?.plays == 7)
    #expect(!model.isLoading)
    var changes = 0
    model.changed = { changes += 1 }
    model.ranking = .hours
    model.ranking = .hours
    #expect(changes == 1)
}

@MainActor @Test func aFailedReadLeavesNoReportForTheNewPeriod() async {
    let model = StatsModel { period in
        guard period == .year else { throw CancellationError() }
        return StatsReport(
            PeriodScan(
                span: PlaySpan(start: 0, end: 86_400), paths: [], buckets: [],
                bucketSeconds: 3600, libraryTracks: 1, undatedPlays: 0),
            firstPlays: FirstPlays(), calendar: .current)
    }
    await model.show(.year)
    #expect(model.periodReport?.span == PlaySpan(start: 0, end: 86_400))
    // All Time's read fails: Past Year's report still shows, but isn't All Time's, so its
    // days don't narrow All Time's table.
    await model.show(.all)
    #expect(model.report != nil)
    #expect(model.periodReport == nil)
}

/// A browser over a copy of the shared library with plays today, 400 days ago and of a file
/// no longer in the library, in a window, its split laid out, `saved` loaded.
@MainActor
private func playedBrowser(_ saved: BrowserState = BrowserState(source: nil)) async throws -> (
    LibraryBrowser, NSWindow, NSSplitView, [TrackRow]
) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let now = Date().timeIntervalSince1970
    let album = rows.filter { $0.albumID == rows[0].albumID }
    for (place, row) in album.enumerated() {
        for play in 0..<3 {
            try index.recordPlay(row.path, at: now - Double(600 * (place * 3 + play) + 60))
        }
    }
    try index.recordPlay(rows[rows.count - 1].path, at: now - 86_400 * 400)
    try index.recordPlay("/elsewhere/gone.flac", at: now - 30)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 150, groupByAlbumArtist: false,
        thumbnails: nil)
    _ = browser.sidebar.view
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    browser.restoreSplit()
    await browser.load(saved)
    let split = try #require(browser.content.view.subviews.first?.subviews.first as? NSSplitView)
    return (browser, window, split, album)
}

@MainActor @Test func statsShowsItsPanelAtItsOwnHeightOverThePeriodsTracks() async throws {
    let (browser, window, split, album) = try await playedBrowser()
    let sidebar = try #require(browser.sidebar as? SidebarController)
    let slot = split.arrangedSubviews[0]
    browser.statsHeight = 320
    browser.showStats(.all)
    try await waitFor("the report") {
        browser.statsModel.report != nil && !browser.statsModel.isLoading
    }
    window.layoutIfNeeded()
    #expect(browser.shownPanel === browser.statsPanel)
    #expect(browser.statsPanel.view.isDescendant(of: slot))
    #expect(abs(slot.frame.height - 320) <= 1)
    #expect(sidebar.selectedSource == .stats(.all))
    let report = try #require(browser.statsModel.report)
    #expect(report.plays == album.count * 3 + 2)
    #expect(report.missingPlays == 1)
    let cards = browser.statsPanel.cards
    #expect(cards.figures.valueLabels.first?.stringValue == number(report.plays))
    #expect(cards.totalsCard.detailLabel.stringValue.contains("1 play not in the library"))
    #expect(cards.lists[.albums]?.rows.first?.name == album[0].album)
    #expect(cards.lists[.tracks]?.rows.contains { $0.dimmed && $0.name == "gone" } == true)
    #expect(
        browser.statsPanel.periods.selectedSegment == StatsPanel.segmentPeriods.firstIndex(of: .all)
    )
    // The table lists the tracks played in the period.
    let played = Set(report.paths.filter(\.inLibrary).map(\.id))
    #expect(played.count == album.count + 1)
    try await waitFor("the period's tracks") { Set(browser.model.trackIDs) == played }

    // Past Week holds a play six days ago, before the calendar's week started on all but its
    // last day, and leaves out one seven days ago and the one 400 days ago; the sidebar's row
    // keeps the period.
    let rows = try browser.index.rows(ids: try browser.index.trackIDs(sortedBy: .path))
    let others = rows.filter { row in !album.contains { $0.id == row.id } }
    let sixDaysAgo = try #require(others.first)
    let calendar = Calendar.current
    for (row, days) in [(sixDaysAgo, -6), (try #require(others.dropFirst().first), -7)] {
        let day = try #require(calendar.date(byAdding: .day, value: days, to: Date()))
        try browser.index.recordPlay(row.path, at: day.timeIntervalSince1970)
    }
    browser.statsPanel.choosePeriod(.week)
    try await waitFor("the week") {
        browser.statsModel.report?.span != nil && !browser.statsModel.isLoading
    }
    #expect(browser.statsModel.report?.plays == album.count * 3 + 2)
    #expect(sidebar.selectedSource == .stats(.week))
    try await waitFor("the week's tracks") {
        Set(browser.model.trackIDs) == Set(album.map(\.id) + [sixDaysAgo.id])
    }

    // The library puts the columns back at their own height.
    browser.show(nil)
    try await waitFor("the library") { browser.shownPanel == nil }
    window.layoutIfNeeded()
    #expect(abs(slot.frame.height - 150) <= 1)
    #expect(sidebar.selectedSource == nil)
    // Stats' row shows the week again.
    browser.showStats()
    try await waitFor("Stats again") { browser.model.filter.source == .stats(.week) }
}

@MainActor @Test func statsSavedAsTheSourceOpensInItsSortOverItsReportsDays() async throws {
    let (browser, _, _, album) = try await playedBrowser(BrowserState(source: .stats(.week)))
    try await waitFor("the week's report and tracks") {
        browser.statsModel.periodReport?.span != nil
            && Set(browser.model.trackIDs) == Set(album.map(\.id))
    }
    #expect(browser.model.filter.source == .stats(.week))
    #expect(browser.model.sortColumn == .playCount && !browser.model.ascending)
    #expect(browser.model.tableSort == (.artist, true))
}

@MainActor @Test func aPeriodsReportListsItsTableOnceWhenItsDaysAreTheTables() async throws {
    let (browser, _, _, album) = try await playedBrowser()
    browser.showStats(.month)
    try await waitFor("the month") {
        browser.statsModel.periodReport != nil && !browser.model.trackIDs.isEmpty
    }
    var reloads: [BrowserChange.Reason] = []
    let changed = browser.model.changed
    browser.model.changed = { change in
        reloads.append(change.reason)
        changed(change)
    }
    browser.statsPanel.choosePeriod(.week)
    try await waitFor("the week") {
        browser.statsModel.periodReport != nil
            && Set(browser.model.trackIDs) == Set(album.map(\.id))
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    // The source change's listing alone; the report's days were the ones it used.
    #expect(reloads == [.user], "\(reloads)")
}

@MainActor @Test func aRowNarrowsStatsTableToItsTracksAndClickedAgainListsThemAll() async throws {
    let (browser, _, _, album) = try await playedBrowser()
    // A selection in a column, hidden while Stats shows, would narrow its table unseen.
    await browser.model.select(.albums, .id(try #require(album[0].albumID)))
    browser.showStats(.month)
    try await waitFor("the report") {
        browser.statsModel.report != nil && !browser.statsModel.isLoading
    }
    #expect(browser.model.filter.selections.isEmpty)
    let panel = browser.statsPanel
    let cards = panel.cards
    #expect(panel.filterButton.isHidden)
    let played = Set(try #require(browser.statsModel.report).paths.filter(\.inLibrary).map(\.id))
    try await waitFor("the period's tracks") { Set(browser.model.trackIDs) == played }

    // An album's row stays in Stats and lists the album's tracks played in the period.
    let albums = try #require(cards.lists[.albums])
    let albumRow = try #require(albums.rows.firstIndex { $0.name == album[0].album })
    albums.clicked(albumRow)
    try await waitFor("the album's tracks") {
        browser.model.filter.stats != nil && Set(browser.model.trackIDs) == Set(album.map(\.id))
    }
    #expect(browser.model.filter.source == .stats(.month))
    #expect(browser.shownPanel === panel)
    #expect(albums.marked == albumRow)
    #expect(!panel.filterButton.isHidden)
    #expect(panel.filterButton.title == album[0].album)

    // Another period keeps it; the button lists every track played again.
    panel.choosePeriod(.year)
    try await waitFor("the year") { browser.model.filter.source == .stats(.year) }
    #expect(browser.model.filter.stats?.title == album[0].album)
    try await waitFor("the year's report") {
        browser.statsModel.report?.span != nil && !browser.statsModel.isLoading
            && browser.statsModel.period == .year
    }
    #expect(albums.marked != nil)
    panel.filterButton.performClick(nil)
    try await waitFor("every track") { browser.model.filter.stats == nil }
    #expect(panel.filterButton.isHidden)
    #expect(albums.marked == nil)

    // A track's row lists it alone, selected; its row clicked again lists them all.
    let tracks = try #require(cards.lists[.tracks])
    let trackRow = try #require(tracks.rows.firstIndex { !$0.dimmed })
    tracks.clicked(trackRow)
    try await waitFor("the track") { browser.model.trackIDs.count == 1 }
    try await waitFor("its selection") { browser.table.table.selectedRowIndexes == [0] }
    #expect(tracks.marked == trackRow)
    tracks.clicked(trackRow)
    try await waitFor("every track again") { browser.model.filter.stats == nil }
    #expect(browser.model.filter.source == .stats(.year))
}

@MainActor @Test func aBarNarrowsStatsToItsSpanAndADoubleClickShowsItsPlays() async throws {
    let (browser, _, _, album) = try await playedBrowser()
    browser.showStats(.month)
    try await waitFor("the report") {
        browser.statsModel.report != nil && !browser.statsModel.isLoading
    }
    let cards = browser.statsPanel.cards
    let report = try #require(browser.statsModel.report)
    let today = try #require(report.bars.lastIndex { $0.plays > 0 })
    let span = report.bars[today].span
    cards.chart.clicked(today)
    try await waitFor("the day's tracks") { browser.model.filter.stats?.item == .span(span) }
    #expect(browser.model.filter.source == .stats(.month))
    #expect(cards.chart.marked == today)
    #expect(
        browser.statsPanel.filterButton.title
            == barTitle(report.bars[today], unit: report.barUnit))
    try await waitFor("the day's rows") { !browser.model.trackIDs.isEmpty }
    #expect(Set(browser.model.trackIDs).isSubset(of: Set(album.map(\.id))))
    // A bar's span is the period's, so another period lists every track again.
    browser.statsPanel.choosePeriod(.year)
    try await waitFor("the year") { browser.model.filter.source == .stats(.year) }
    #expect(browser.model.filter.stats == nil)

    browser.show(.stats(.month))
    try await waitFor("the month's report") {
        browser.statsModel.period == .month && !browser.statsModel.isLoading
    }
    cards.chart.doubleClicked(today)
    try await waitFor("the day's plays") {
        browser.model.filter.source == .plays(span) && browser.timelineModel.isLoaded
    }
    #expect(browser.showsTimeline)
    #expect(browser.timelineModel.entries.count == report.bars[today].plays)
}

@MainActor @Test func aClickInYearInReviewNarrowsStatsForThatYear() async throws {
    let (browser, _, _, album) = try await playedBrowser()
    let year = Calendar.current.component(.year, from: Date())
    browser.showYearInReview(year)
    try await waitFor("the window") { browser.yearReview?.year == year }
    let review = try #require(browser.yearReview)
    let albums = try #require(review.cards.lists[.albums])
    let row = try #require(albums.rows.firstIndex { $0.name == album[0].album })
    albums.clicked(row)
    try await waitFor("Stats for the year") {
        browser.model.filter.source == .stats(.chosenYear(year))
            && Set(browser.model.trackIDs) == Set(album.map(\.id))
    }
    #expect(browser.statsPanel.filterButton.title == album[0].album)
    review.close()
}

/// The text field of the sheet over `window`.
@MainActor private func sheetField(over window: NSWindow) throws -> NSTextField {
    let sheet = try #require(window.attachedSheet, "no sheet")
    var views = [try #require(sheet.contentView)]
    while let view = views.popLast() {
        if let field = view as? NSTextField, field.isEditable { return field }
        views += view.subviews
    }
    throw CocoaError(.featureUnsupported)
}

@MainActor @Test func aTopListIsSavedAsAPlaylistOfItsPlayedTracksUnderTheNameGiven()
    async throws
{
    let (browser, window, _, album) = try await playedBrowser()
    browser.showStats(.week)
    try await waitFor("the report") {
        browser.statsModel.report != nil && !browser.statsModel.isLoading
    }
    let report = try #require(browser.statsModel.report)
    let made = "Top Artists, " + statsPlaylistPeriod(report.span)
    let before = browser.playlists.count
    // A click by its action: `performClick` runs the main run loop, which ends the test
    // process once the loop has nothing left to wait for.
    let save = try #require(browser.statsPanel.cards.saveButtons[.artists])

    // Cancel saves nothing.
    _ = save.sendAction(save.action, to: save.target)
    #expect(try sheetField(over: window).stringValue == made)
    window.endSheet(try #require(window.attachedSheet), returnCode: .alertSecondButtonReturn)
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(browser.playlists.count == before)

    // The sheet asks first; its button saves the name in its field.
    _ = save.sendAction(save.action, to: save.target)
    let field = try sheetField(over: window)
    #expect(field.stringValue == made)
    #expect(browser.playlists.count == before)
    field.stringValue = "  Past Week's Artists "
    window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
    try await waitFor("the playlist") {
        browser.playlists.contains { $0.name == "Past Week's Artists" }
    }
    let playlist = try #require(browser.playlists.first { $0.name == "Past Week's Artists" })
    #expect(browser.playlists.count == before + 1)
    try await waitFor("its tracks") { browser.model.filter.source == .playlist(playlist.id) }
    try await waitFor("its rows") { Set(browser.model.trackIDs) == Set(album.map(\.id)) }
}

@MainActor @Test func yearInReviewSavesItsOwnYearsListOverItsWindow() async throws {
    let (browser, window, _, _) = try await playedBrowser()
    browser.showStats(.week)
    try await waitFor("the week") {
        browser.statsModel.report != nil && !browser.statsModel.isLoading
    }
    // The year of the track played 400 days ago, whose list differs from the week's.
    let year = Calendar.current.component(
        .year, from: Date(timeIntervalSinceNow: -86_400 * 400))
    browser.showYearInReview(year)
    try await waitFor("the review") { browser.yearReview?.year == year }
    let review = try #require(browser.yearReview)
    let reviewWindow = try #require(review.window)
    let tracks = try #require(review.cards.lists[.tracks]?.rows)
    #expect(tracks.count == 1)
    let before = browser.playlists.count
    let save = try #require(review.cards.saveButtons[.tracks])
    _ = save.sendAction(save.action, to: save.target)
    #expect(window.attachedSheet == nil)
    let field = try sheetField(over: reviewWindow)
    #expect(field.stringValue == "Top Tracks, \(year)")
    reviewWindow.endSheet(
        try #require(reviewWindow.attachedSheet), returnCode: .alertFirstButtonReturn)
    try await waitFor("the playlist") { browser.playlists.count == before + 1 }
    let playlist = try #require(browser.playlists.first { $0.name == "Top Tracks, \(year)" })
    let yearsTracks = try #require(review.cards.report).paths.filter(\.inLibrary).map(\.id)
    try await waitFor("its rows") {
        browser.model.filter.source == .playlist(playlist.id)
            && browser.model.trackIDs == yearsTracks
    }
    review.close()
}

@MainActor @Test func theCommandLineGetsTheReportAsTextOrJSON() async throws {
    let (browser, _, _, album) = try await playedBrowser()
    let text = try await browser.statsText(.all, json: false)
    #expect(text.hasPrefix("All Time"))
    #expect(text.contains(count(album.count * 3 + 2, "play")))
    #expect(text.contains("Top Albums"))
    let json = try await browser.statsText(.week, json: true)
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["period"] as? String == "week")
    let report = try #require(object["report"] as? [String: Any])
    #expect(report["plays"] as? Int == album.count * 3 + 1)
    let top = try #require(report["top"] as? [String: [String: [[String: Any]]]])
    #expect(top["plays"]?["albums"]?.first?["name"] as? String == album[0].album)
}

@MainActor @Test func yearInReviewShowsTheYearsReport() async throws {
    let (browser, _, _, album) = try await playedBrowser()
    let year = Calendar.current.component(.year, from: Date())
    browser.showYearInReview(year)
    try await waitFor("the window") { browser.yearReview?.year == year }
    let review = try #require(browser.yearReview)
    #expect(review.window?.title == "Year in Review \(year)")
    #expect(review.months.bars.count == 12)
    #expect(review.months.marked != nil)
    #expect(review.cards.lists[.albums]?.rows.first?.name == album[0].album)
    #expect(review.highlights.figures.count == 4)
    review.close()
}

@MainActor @Test func theTotalsSayHowManyPlaysCameFromAnImport() {
    var report = StatsReport(
        PeriodScan(
            span: nil, paths: [], buckets: [], bucketSeconds: 3600, libraryTracks: 1,
            undatedPlays: 30, importedPlays: 12), firstPlays: FirstPlays(), calendar: .current)
    report.plays = 40
    #expect(report.importedPlays == 12)
    #expect(StatsCards.notes(report).contains("12 plays from an import"))
    #expect(StatsCards.notes(report).contains("+30 imported plays without dates"))
    #expect(StatsCards.figures(report).first?.help?.hasPrefix("12 plays from an import.") == true)
    #expect(
        statsSummary(report, period: .all, ranking: .plays).contains(
            "12 plays from an import, each a track's last play there"))
}

@Test func aSavedListIsNamedForItsDaysOrItsYear() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    // 5 November 2026, 10:00 there.
    let now = Date(timeIntervalSince1970: 1_793_901_600)
    let pastYear = StatsPeriod.year.span(now: now, calendar: calendar)
    let name = statsPlaylistPeriod(pastYear, calendar: calendar)
    // The days it covers, not the year it started in.
    #expect(name == pastYear?.title(calendar: calendar))
    #expect(name.contains("2025") && name.contains("2026"))
    let year = StatsPeriod.chosenYear(2024).span(calendar: calendar)
    #expect(statsPlaylistPeriod(year, calendar: calendar) == "2024")
    #expect(statsPlaylistPeriod(nil) == "All Time")
}

/// The panel's cards, their totals filled, in a flow `width` points wide, laid out.
@MainActor private func flowedCards(width: CGFloat) -> (StatsCards, StatsFlowView) {
    let cards = StatsCards()
    let report = StatsReport(
        PeriodScan(
            span: nil, paths: [], buckets: [], bucketSeconds: 3600, libraryTracks: 1,
            undatedPlays: 0), firstPlays: FirstPlays(), calendar: .current)
    cards.figures.figures = StatsCards.figures(report)
    let flow = StatsFlowView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
    flow.cards = cards.all
    flow.layoutSubtreeIfNeeded()
    return (cards, flow)
}

/// How many rows the figures are in, and how many in the widest.
@MainActor private func figureRows(_ figures: StatsFigures) -> (rows: Int, widest: Int) {
    let tops = figures.columns.map(\.frame.minY)
    let counts = Dictionary(grouping: tops, by: { $0 }).values.map(\.count)
    return (counts.count, counts.max() ?? 0)
}

@MainActor @Test func theTotalsBesidePlaysPerDayAreAsTallAsItInTwoRows() {
    let (cards, _) = flowedCards(width: 2000)
    let totals = cards.totalsCard.frame
    let chart = cards.chartCard.frame
    #expect(totals.minY == chart.minY && totals.maxX < chart.minX, "\(totals) \(chart)")
    #expect(totals.height == chart.height)
    #expect(figureRows(cards.figures) == (2, 3))
    for column in cards.figures.columns {
        #expect(column.frame.maxY <= cards.figures.bounds.height)
        #expect(column.frame.width > 100)
    }

    // On a row of their own they keep their height, the figures in one row.
    let (narrow, _) = flowedCards(width: 1000)
    #expect(narrow.totalsCard.frame.height == narrow.totalsCard.heightPoints)
    #expect(narrow.chartCard.frame.minY > narrow.totalsCard.frame.maxY)
    #expect(figureRows(narrow.figures) == (1, 6))
}

@MainActor @Test func aOneColumnCardIs300To455PointsWideOnceTwoColumnsFit() {
    let cards = StatsCards()
    let flow = StatsFlowView()
    flow.cards = cards.all
    let clock = cards.clockCard
    var narrowest = CGFloat.infinity
    var widest: CGFloat = 0
    for width in stride(from: 2 * flow.insetPoints + 610, through: 2400, by: 7) {
        flow.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        flow.layout()
        narrowest = min(narrowest, clock.frame.width)
        widest = max(widest, clock.frame.width)
    }
    #expect(narrowest >= 300, "\(narrowest)")
    // Just short of three columns, two share 3 × 300 + 2 × 10 points less a spacing.
    #expect(widest > 450 && widest < 455, "\(widest)")
}
