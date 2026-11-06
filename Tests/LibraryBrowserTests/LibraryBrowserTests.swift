import AppKit
import Foundation
import KeyChord
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor @Test func watcherEventsArriveInTheOrderSent() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let send = browser.watcherEvents
    let folders = (0..<200).map { "/Music/\($0)" }
    // From another thread, as the watcher sends them: each folder's progress, then its outcome.
    await Task.detached {
        for folder in folders {
            send(.scanning(folder: folder, ScanProgress()))
            send(.scanned(folder: folder, ScanSummary()))
        }
        send(.scanning(folder: "/Music/last", ScanProgress()))
    }.value
    let deadline = Date().addingTimeInterval(10)
    while browser.status.scanning["/Music/last"] == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(Array(browser.status.scanning.keys) == ["/Music/last"])
}

@MainActor @Test func aDiscardShowsOnceThenIsForgottenAndLaterOnesAddToIt() async throws {
    let source = try browserLibrary.get().databaseURL
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("discards-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: source.path + suffix) {
        try FileManager.default.copyItem(
            atPath: source.path + suffix, toPath: databaseURL.path + suffix)
    }
    let index = try LibraryIndex(at: databaseURL)
    let record = try index.database.prepare(
        "INSERT INTO schema_discards (discarded_seconds, detail) VALUES (0, ?)")
    try record.run("first")
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let state = BrowserState(source: nil)
    await browser.load(state)
    #expect(browser.status.notices.map { $0.hasSuffix("first") } == [true])
    #expect(try index.discards().isEmpty)
    // The bar offers the list the notice is in.
    #expect(browser.problemsButtonTitle == browser.status.problemsTitle)
    #expect(browser.problemsButtonTitle != nil)

    try record.run("second")
    await browser.load(state)
    #expect(browser.status.notices.map { $0.split(separator: " ").last } == ["first", "second"])
    #expect(try index.discards().isEmpty)
}

@MainActor @Test func aCommandWithNoTrackToActOnBeepsAndSaysSo() throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    var beeps = 0
    browser.beep = { beeps += 1 }
    browser.reportCommand("couldn't rate the tracks", OnlyMissingFiles())
    #expect(beeps == 1)
    #expect(browser.statusText == "couldn't rate the tracks: \(OnlyMissingFiles())")
    // Other failures say so without the beep.
    browser.reportCommand("couldn't rate the tracks", LibraryError.playsNotTracks)
    #expect(beeps == 1)
    #expect(browser.statusText.hasSuffix("\(LibraryError.playsNotTracks)"))
}

@MainActor @Test func theSidebarListsTheLibraryAndPlaylistsButNoFolders() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let sidebar = try #require(browser.sidebar as? SidebarController)
    _ = sidebar.view
    await browser.load(BrowserState(source: nil))
    let outline = sidebar.outline
    // The library's group and the playlists'; the watched folders are in Settings.
    #expect(outline.numberOfChildren(ofItem: nil) == 2)
    func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    #expect(buttons(in: sidebar.view).isEmpty)
}

@MainActor @Test func hiddenPanesLeaveNoDividerAndComeBackAtTheirHeight() throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 150, groupByAlbumArtist: false,
        thumbnails: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    browser.restoreSplit()
    let split = try #require(browser.content.view.subviews.first?.subviews.first as? NSSplitView)
    let panes = split.arrangedSubviews[0]
    #expect(abs(panes.frame.height - 150) <= 1)

    browser.toggleBrowser()
    for height in [500.0, 700.0] {
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: height), display: false)
        window.layoutIfNeeded()
        #expect(!browser.isBrowserVisible)
        #expect(browser.splitView(split, shouldHideDividerAt: 0))
        #expect(!browser.focusAreas.contains { $0.isDescendant(of: panes) })
    }
    browser.toggleBrowser()
    window.layoutIfNeeded()
    #expect(browser.isBrowserVisible)
    #expect(!browser.splitView(split, shouldHideDividerAt: 0))
    #expect(abs(panes.frame.height - 150) <= 1)
}

@MainActor @Test func hidingThePanesSelectsAllSoNothingHiddenNarrowsTheTable() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let index = try LibraryIndex(at: databaseURL)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 150, groupByAlbumArtist: false,
        thumbnails: nil)
    var states: [BrowserState] = []
    browser.stateChanged = { states.append($0) }
    await browser.load(BrowserState(source: nil))
    let genre = try #require(try index.genres().first)
    await browser.showOnly(.genre, id: genre.id)
    #expect(states.last?.columns[0].selection != nil)
    browser.toggleBrowser()
    let deadline = Date().addingTimeInterval(10)
    while states.last?.columns[0].selection != nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(states.last?.columns[0].selection == nil)
    browser.selectAllTracks()
    #expect(try await browser.selectedPaths().count == (try index.trackCount()))
    // Shown again, they start at All.
    browser.toggleBrowser()
    #expect(browser.isBrowserVisible)
    #expect(states.last?.columns[0].selection == nil)
}

@MainActor @Test func theScanBarAnimatesOnlyWhileTheStatusBarShows() async throws {
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: try browserLibrary.get().databaseURL),
        index: try LibraryIndex(at: try browserLibrary.get().databaseURL),
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    await browser.load(BrowserState(source: nil))
    browser.libraryChanged(.scanning(folder: "/music", ScanProgress()))
    #expect(browser.scanIndicatorAnimates)
    browser.toggleStatusBar()
    #expect(!browser.isStatusBarVisible && !browser.scanIndicatorAnimates)
    // Progress arriving while it's hidden doesn't start it.
    browser.libraryChanged(.scanning(folder: "/music", ScanProgress()))
    #expect(!browser.scanIndicatorAnimates)
    browser.toggleStatusBar()
    #expect(browser.scanIndicatorAnimates)
}

/// Files the tag editor wrote and the watcher read again refresh the rows and columns at once;
/// a rescan that read nothing doesn't.
@MainActor @Test func editedFilesReadAgainRefreshTheBrowser() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false, thumbnails: nil)
    await browser.load(BrowserState(source: nil))
    var refreshes = 0
    browser.libraryRefreshed = { refreshes += 1 }
    browser.libraryChanged(.edited(ScanSummary()))
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(refreshes == 0)
    var summary = ScanSummary()
    summary.read = 1
    browser.libraryChanged(.edited(summary))
    let deadline = Date().addingTimeInterval(5)
    while refreshes == 0, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(refreshes == 1)
}

@MainActor @Test func leftAndRightMoveBetweenThePanesAndGoToTheRegistryElsewhere() throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 150, groupByAlbumArtist: false,
        thumbnails: nil)
    var sent: [KeyChord] = []
    browser.keyCommand = { chords in
        sent += chords
        return .ran
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = NSStackView(views: [browser.sidebar.view, browser.content.view])
    // The sidebar, the genre, artist and album panes, then the track table.
    let areas = browser.focusAreas
    #expect(areas.count == 5)
    func press(_ key: KeyChord.Key, in view: NSView) throws {
        #expect(window.makeFirstResponder(view))
        let characters = String(
            UnicodeScalar(key == .right ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey)!)
        view.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false,
                    keyCode: key == .right ? 124 : 123)))
    }

    try press(.right, in: areas[1])
    #expect(window.firstResponder === areas[2])
    try press(.left, in: areas[1])
    #expect(window.firstResponder === areas[4])
    #expect(sent.isEmpty)

    // The track table and the sidebar leave them to the registry, which skips tracks.
    try press(.right, in: areas[4])
    try press(.left, in: areas[0])
    #expect(sent == [KeyChord(.right), KeyChord(.left)])
}

@MainActor @Test func aClickOnTheTotalsCyclesThemAndTheSelectionShowsAsItChanges() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    var reported: [StatusTotals] = []
    browser.statusTotalsChanged = { reported.append($0) }
    await browser.load(BrowserState(source: nil))
    // The totals are read off the main thread, after the rows show.
    try await waitFor("the list's totals") {
        browser.listTotals.count == browser.model.trackIDs.count
    }
    #expect(browser.listTotals.sizeBytes > 0)
    let list = browser.listTotals.text()
    #expect(browser.statusText == list)

    browser.table.table.selectRowIndexes([0], byExtendingSelection: false)
    let first = try await browser.reader.trackTotals(ids: [browser.model.trackIDs[0]])
    let one = first.text(selected: true)
    #expect(one.hasPrefix("1 track selected, "))
    try await waitFor("the selection's totals") { browser.statusText == "\(list) (\(one))" }
    browser.showNextTotals()
    #expect(browser.statusText == list)
    browser.showNextTotals()
    #expect(browser.statusText == one)
    browser.table.table.deselectAll(nil)
    #expect(browser.statusText == list)
    browser.showNextTotals()
    #expect(reported == [.list, .selection, .listAndSelection])
}

@MainActor @Test func theStatusBarMatchesTheTableHeaderAndHidesWithIt() throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    if #available(macOS 26, *) {
        #expect(browser.statusArea is NSGlassEffectView)
    } else {
        #expect((browser.statusArea as? NSVisualEffectView)?.material == .titlebar)
    }
    let header = try #require(browser.table.table.headerView)
    #expect(header.frame.height > 0)
    #expect(browser.statusArea.frame.height == header.frame.height)
    // The lists' font, centered top to bottom.
    let label = browser.statusLabel
    #expect(label.font == TextCell.font)
    let middle = label.convert(label.bounds, to: browser.statusArea).midY
    #expect(abs(middle - browser.statusArea.bounds.midY) <= 1)
    #expect(browser.statusArea.superview != nil)
    browser.toggleStatusBar()
    #expect(browser.statusArea.isHidden && !browser.isStatusBarVisible)
}

@MainActor @Test func clearingTheSearchShowsWhatItHid() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    await browser.load(BrowserState(source: nil))
    let all = browser.model.trackIDs.count
    // Out of any window, as when the user takes Search out of the toolbar.
    #expect(!browser.isSearchShown)
    browser.searchField.stringValue = "zzqx"
    browser.searchField.sendAction(browser.searchField.action, to: browser.searchField.target)
    try await waitFor("the search") { browser.model.trackIDs.isEmpty }
    browser.clearSearch()
    #expect(browser.searchField.stringValue.isEmpty)
    try await waitFor("every track") { browser.model.trackIDs.count == all }
}

@MainActor @Test func showsAllMusicOnlyWhileNothingNarrowsTheTable() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    await browser.load(BrowserState(source: nil))
    #expect(browser.showsAllMusic)
    await browser.model.setSource(.history)
    #expect(!browser.showsAllMusic)
    await browser.model.setSource(nil)
    #expect(browser.showsAllMusic)
    await browser.model.setSearch("a")
    #expect(!browser.showsAllMusic)
    _ = await browser.model.showAll()
    #expect(browser.showsAllMusic)
    let genre = try #require(browser.model.genres.first)
    await browser.model.select(.genre, id: genre.id)
    #expect(!browser.showsAllMusic)
}

@MainActor @Test func theSearchIsSavedAndComesBackInTheFieldAndTheTable() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    func launched() throws -> LibraryBrowser {
        LibraryBrowser(
            reader: try LibraryReader(databaseURL: databaseURL),
            index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
            browserHeight: 100, groupByAlbumArtist: false, thumbnails: nil)
    }
    let first = try launched()
    var saved = BrowserState(source: nil)
    first.stateChanged = { saved = $0 }
    await first.load(saved)
    let everything = first.model.trackIDs
    let title = try #require(try await first.model.trackNames().first?.title)
    first.searchField.stringValue = title
    _ = first.searchField.target?.perform(first.searchField.action)
    try await waitFor("the search") { first.model.filter.search == title }
    #expect(saved.search == title)
    #expect(first.model.trackIDs.count < everything.count)

    let second = try launched()
    await second.load(saved)
    #expect(second.searchField.stringValue == title)
    #expect(second.model.filter.search == title)
    #expect(second.model.trackIDs == first.model.trackIDs)
}
