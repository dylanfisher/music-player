import AppKit
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

/// A report whose every check found track `id`.
private func report(_ id: Int64) -> HealthReport {
    HealthReport(
        Dictionary(
            uniqueKeysWithValues: HealthCheck.allCases.map { ($0, HealthFindings(trackIDs: [id])) }
        ))
}

@MainActor @Test func aRunThatFinishesAfterANewerOneIsDropped() async throws {
    var pending: [CheckedContinuation<HealthReport, any Error>] = []
    var shown: [HealthReport] = []
    let model = HealthModel(
        build: { try await withCheckedThrowingContinuation { pending.append($0) } },
        show: { shown.append($0) })
    var changes = 0
    model.changed = { changes += 1 }
    let first = Task { await model.run() }
    try await waitFor("the first build") { pending.count == 1 }
    let second = Task { await model.run() }
    try await waitFor("the second build") { pending.count == 2 }
    pending[1].resume(returning: report(2))
    await second.value
    #expect(!model.isRunning)
    pending[0].resume(returning: report(1))
    await first.value
    #expect(model.report == report(2))
    #expect(shown == [report(2)])
    #expect(changes == 1)
}

@MainActor @Test func aFailedRunIsReportedAndAnOvertakenFailureIsNot() async throws {
    struct Broken: Error {}
    var pending: [CheckedContinuation<HealthReport, any Error>] = []
    let model = HealthModel(
        build: { try await withCheckedThrowingContinuation { pending.append($0) } },
        show: { _ in })
    var failures: [String] = []
    model.failed = { failures.append($0) }
    let first = Task { await model.run() }
    try await waitFor("the first build") { pending.count == 1 }
    let second = Task { await model.run() }
    try await waitFor("the second build") { pending.count == 2 }
    pending[0].resume(throwing: Broken())
    await first.value
    #expect(failures.isEmpty)
    pending[1].resume(throwing: Broken())
    await second.value
    #expect(failures.count == 1)
    #expect(model.report == nil)
    #expect(!model.isRunning)
}

@MainActor @Test func aNewerRunThatFailsLeavesTheShownReportAndTableAgreeing() async throws {
    struct Broken: Error {}
    var builds: [CheckedContinuation<HealthReport, any Error>] = []
    var shows: [CheckedContinuation<Void, any Error>] = []
    var shown: [HealthReport] = []
    let model = HealthModel(
        build: { try await withCheckedThrowingContinuation { builds.append($0) } },
        show: { report in
            try await withCheckedThrowingContinuation { shows.append($0) }
            shown.append(report)
        })
    let first = Task { await model.run() }
    try await waitFor("the first build") { builds.count == 1 }
    builds[0].resume(returning: report(1))
    try await waitFor("the first show") { shows.count == 1 }
    // A second run starts while the first is being shown, and fails.
    let second = Task { await model.run() }
    try await waitFor("the second build") { builds.count == 2 }
    builds[1].resume(throwing: Broken())
    await second.value
    shows[0].resume()
    await first.value
    #expect(shown == [report(1)])
    #expect(model.report == report(1))
    #expect(!model.isRunning)
}

/// A browser over the shared library in a window, its split laid out, the library loaded.
@MainActor
private func browserInWindow(browserHeight: Int = 150) async throws -> (
    LibraryBrowser, NSWindow, NSSplitView
) {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: browserHeight, groupByAlbumArtist: false, thumbnails: nil)
    _ = browser.sidebar.view
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    browser.restoreSplit()
    await browser.load(BrowserState(source: nil))
    let split = try #require(browser.content.view.subviews.first?.subviews.first as? NSSplitView)
    return (browser, window, split)
}

@MainActor @Test func showLibraryHealthPutsItsPanelInTheColumnsPlace() async throws {
    let (browser, window, split) = try await browserInWindow()
    let sidebar = try #require(browser.sidebar as? SidebarController)
    let slot = split.arrangedSubviews[0]
    browser.checkHealth()
    try await waitFor("the report") { browser.health.report != nil }
    try await waitFor("the first check") { browser.model.filter.source == .health(.unreadable) }
    window.layoutIfNeeded()
    let panel = browser.healthPanel
    #expect(browser.shownPanel === panel)
    #expect(panel.view.isDescendant(of: slot))
    #expect(!browser.showsColumns)
    #expect(!browser.focusAreas.contains { $0.isDescendant(of: slot) })
    #expect(abs(slot.frame.height - 150) <= 1)
    // No sidebar row stands for it, so none is selected.
    #expect(sidebar.outline.selectedRow == -1)
    let report = try #require(browser.health.report)
    #expect(panel.tiles.count == HealthCheck.allCases.count)
    for (check, tile) in panel.tiles {
        #expect(tile.countLabel.stringValue == number(report[check].count), "\(check)")
        #expect(tile.isSelected == (check == .unreadable), "\(check)")
    }
    #expect(panel.statusLabel.stringValue.hasPrefix("Checked at "))

    // A tile lists its check's tracks below.
    let expected = Set(try browser.index.paths(ids: report[.noAlbumArtist].trackIDs).values)
    try #require(!expected.isEmpty)
    try #require(panel.tiles[.noAlbumArtist]).clicked()
    try await waitFor("the check's tracks") {
        browser.selectAllTracks()
        return Set(try await browser.selectedPaths()) == expected
    }
    #expect(panel.tiles[.noAlbumArtist]?.isSelected == true)
    #expect(panel.tiles[.unreadable]?.isSelected == false)

    // Another source puts the columns back.
    browser.show(nil)
    try await waitFor("the library") { browser.model.filter.source == nil }
    window.layoutIfNeeded()
    #expect(browser.shownPanel == nil)
    #expect(panel.view.superview == nil)
    #expect(browser.showsColumns)
    #expect(abs(slot.frame.height - 150) <= 1)
    #expect(sidebar.selectedSource == nil && sidebar.outline.selectedRow >= 0)
}

@MainActor @Test func aTileTakesTheClickOnItsLabels() throws {
    let panel = HealthPanel()
    _ = panel.view
    var selected: [HealthCheck] = []
    panel.select = { selected.append($0) }
    let tile = try #require(panel.tiles[.warnings])
    tile.frame = NSRect(x: 0, y: 0, width: 200, height: 46)
    tile.layoutSubtreeIfNeeded()
    // In the superview's coordinates, over the title.
    #expect(tile.titleLabel.frame.contains(NSPoint(x: 12, y: 30)))
    #expect(tile.hitTest(NSPoint(x: 12, y: 30)) === tile)
    #expect(tile.hitTest(NSPoint(x: 300, y: 30)) == nil)
    tile.mouseDown(with: NSEvent())
    #expect(selected == [.warnings])
}

@MainActor @Test func thePanelShowsWithTheBrowserHidden() async throws {
    let (browser, window, split) = try await browserInWindow(browserHeight: 180)
    let slot = split.arrangedSubviews[0]
    browser.toggleBrowser()
    #expect(slot.isHidden)
    browser.checkHealth()
    try await waitFor("the panel") { browser.shownPanel != nil }
    window.layoutIfNeeded()
    #expect(!slot.isHidden)
    #expect(!browser.splitView(split, shouldHideDividerAt: 0))
    #expect(abs(slot.frame.height - 180) <= 1)
    #expect(!browser.isBrowserVisible)
    browser.show(.history)
    try await waitFor("History") { browser.shownPanel == nil }
    #expect(slot.isHidden)
    #expect(browser.splitView(split, shouldHideDividerAt: 0))
    #expect(!browser.showsColumns)
}

@MainActor @Test func showingACheckSelectsAllInTheHiddenColumns() async throws {
    let (browser, _, _) = try await browserInWindow()
    var states: [BrowserState] = []
    browser.stateChanged = { states.append($0) }
    let genre = try #require(try browser.index.genres().first)
    await browser.showOnly(.genre, id: genre.id)
    #expect(states.last?.columns[0].selection != nil)
    browser.checkHealth()
    try await waitFor("the check, at All") {
        states.last?.source == .health(.unreadable) && states.last?.columns[0].selection == nil
    }
}

@MainActor @Test func aSavedCheckShowsTheLibrary() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false, thumbnails: nil)
    let sidebar = try #require(browser.sidebar as? SidebarController)
    _ = sidebar.view
    await browser.load(BrowserState(source: .health(.noAlbumArtist)))
    #expect(browser.model.filter.source == nil)
    #expect(browser.shownPanel == nil)
    #expect(sidebar.selectedSource == nil && sidebar.outline.selectedRow >= 0)
}

@MainActor @Test func deletingAPlaylistRunsTheReportAgain() async throws {
    let root = try browserLibrary.get().root
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let kept = root + "/Crimson Tides"
    let gone = try #require(rows.first { !$0.path.hasPrefix(kept + "/") })
    let playlist = try index.createPlaylist(named: "Mix", rules: nil)
    _ = try index.addToPlaylist(playlist, trackIDs: [gone.id])
    // The track's file leaves the index, so the playlist's entry is lost.
    _ = try index.removeFiles(outside: [kept])
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    _ = browser.sidebar.view
    await browser.load(BrowserState(source: nil))
    browser.checkHealth()
    try await waitFor("the first report") { browser.health.report?[.missingEntries].count == 1 }
    browser.deletePlaylist(playlist)
    try await waitFor("a report without the entry") {
        browser.health.report?[.missingEntries].count == 0
    }
}
