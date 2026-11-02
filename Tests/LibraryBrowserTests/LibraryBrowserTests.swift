import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor @Test func watcherEventsArriveInTheOrderSent() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false)
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
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false)
    let state = BrowserState(source: nil, genre: nil, artist: nil, album: nil)
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
        browserHeight: 100, groupByAlbumArtist: false)
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
        browserHeight: 100, groupByAlbumArtist: false)
    let sidebar = try #require(browser.sidebar as? SidebarController)
    _ = sidebar.view
    await browser.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
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
        browserHeight: 150, groupByAlbumArtist: false)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = browser.content.view
    window.layoutIfNeeded()
    browser.restoreSplit()
    let split = try #require(browser.content.view.subviews.first as? NSSplitView)
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
        layout: AppState().trackTable.defaultValue, browserHeight: 150, groupByAlbumArtist: false)
    var states: [BrowserState] = []
    browser.stateChanged = { states.append($0) }
    await browser.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    let genre = try #require(try index.genres().first)
    await browser.showOnly(.genre, id: genre.id)
    #expect(states.last?.genre != nil)
    browser.toggleBrowser()
    let deadline = Date().addingTimeInterval(10)
    while states.last?.genre != nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(states.last?.genre == nil)
    browser.selectAllTracks()
    #expect(try await browser.selectedPaths().count == (try index.trackCount()))
    // Shown again, they start at All.
    browser.toggleBrowser()
    #expect(browser.isBrowserVisible)
    #expect(states.last?.genre == nil)
}

@MainActor @Test func theScanBarAnimatesOnlyWhileTheStatusBarShows() async throws {
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: try browserLibrary.get().databaseURL),
        index: try LibraryIndex(at: try browserLibrary.get().databaseURL),
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false)
    await browser.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
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
