import AppKit
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

/// A browser over a copy of the shared library with plays this week, a year ago and of a file
/// no longer in the library, in a window, its split laid out, the library loaded.
@MainActor
private func playedBrowser() async throws -> (LibraryBrowser, NSWindow, NSSplitView, [TrackRow]) {
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
    await browser.load(BrowserState(source: nil))
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

    // This Week leaves out last year's play; the sidebar's row keeps the period.
    browser.statsPanel.choosePeriod(.week)
    try await waitFor("the week") {
        browser.statsModel.report?.span != nil && !browser.statsModel.isLoading
    }
    #expect(browser.statsModel.report?.plays == album.count * 3 + 1)
    #expect(sidebar.selectedSource == .stats(.week))
    try await waitFor("the week's tracks") { Set(browser.model.trackIDs) == Set(album.map(\.id)) }

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

@MainActor @Test func aBarShowsItsSpansPlaysAndARowGoesToItsAlbum() async throws {
    let (browser, _, _, album) = try await playedBrowser()
    browser.showStats(.month)
    try await waitFor("the report") {
        browser.statsModel.report != nil && !browser.statsModel.isLoading
    }
    let cards = browser.statsPanel.cards
    let bars = try #require(browser.statsModel.report?.bars)
    let today = try #require(bars.lastIndex { $0.plays > 0 })
    cards.chart.clicked(today)
    try await waitFor("the day's plays") {
        browser.model.filter.source == .plays(bars[today].span) && browser.timelineModel.isLoaded
    }
    #expect(browser.showsTimeline)
    #expect(browser.timelineModel.entries.count == bars[today].plays)
    #expect(browser.timelineModel.span == bars[today].span)

    // Back to Stats, then an album row shows the whole library at the album's first track.
    browser.show(.stats(.month))
    try await waitFor("Stats") { browser.shownPanel === browser.statsPanel }
    let albumRow = try #require(cards.lists[.albums]?.rows.firstIndex { $0.name == album[0].album })
    try #require(cards.lists[.albums]).clicked(albumRow)
    try await waitFor("the album in the library") {
        browser.model.filter.source == nil && !browser.table.table.selectedRowIndexes.isEmpty
    }
    let selected = browser.model.ids(ofRows: browser.table.table.selectedRowIndexes)
    #expect(Set(selected).isSubset(of: Set(album.map(\.id))))
}

@MainActor @Test func aTopListIsSavedAsAPlaylistOfItsPlayedTracks() async throws {
    let (browser, _, _, album) = try await playedBrowser()
    browser.showStats(.week)
    try await waitFor("the report") {
        browser.statsModel.report != nil && !browser.statsModel.isLoading
    }
    browser.statsPanel.cards.actions.savePlaylist(.artists)
    try await waitFor("the playlist") {
        browser.playlists.contains { $0.name.hasPrefix("Top Artists, ") }
    }
    let playlist = try #require(browser.playlists.first { $0.name.hasPrefix("Top Artists, ") })
    try await waitFor("its tracks") { browser.model.filter.source == .playlist(playlist.id) }
    try await waitFor("its rows") { Set(browser.model.trackIDs) == Set(album.map(\.id)) }
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
