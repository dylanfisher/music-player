import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser
@testable import Recommender

/// A browser over a copy of the shared library in a window, whose Rediscover asks a stand-in
/// service that answers the day with `pick` of the library's albums, best first, each keyed and
/// titled as this Mac's profile has it; and those albums by id, best first.
@MainActor
private func rediscoverBrowser(
    calls: RediscoverCalls, pick: ([Int64]) -> [Int64] = { Array($0.suffix(2).reversed()) }
) async throws -> (LibraryBrowser, NSWindow, [Int64]) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let albums = try index.libraryProfile().albums
    let ids = pick(albums.compactMap { albumID(profileKey: $0.key) })
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
    await browser.load(BrowserState(source: nil))
    var day = rediscoverDay([])
    day.albums = ids.map { id in
        var album = rediscovered(profileKey(albumID: id))
        album.title = albums.first { $0.key == profileKey(albumID: id) }!.title
        return album
    }
    let answer = day
    browser.rediscoverService = {
        RediscoverService(
            day: { asked throws(RecommenderError) in
                await MainActor.run { calls.calls.append("day \(asked)") }
                return answer
            },
            notNow: { _ throws(RecommenderError) in throw serviceError(.cancelled) },
            undoNotNow: { _ throws(RecommenderError) in throw serviceError(.cancelled) })
    }
    browser.sendProfile = { force in
        calls.calls.append(force ? "send profile, forced" : "send profile")
        return .unchanged
    }
    return (browser, window, ids)
}

/// Waits until the table lists only tracks of the albums `ids`.
@MainActor
private func waitForTheDay(_ browser: LibraryBrowser, _ ids: [Int64]) async throws {
    try await waitFor("the day's tracks") {
        let tracks = browser.model.trackIDs
        guard browser.model.filter.source == .rediscover, !tracks.isEmpty else { return false }
        let albums = try await browser.reader.albumIDs(ids: tracks)
        return tracks.allSatisfy { albums[$0].map(ids.contains) == true }
    }
}

@MainActor @Test func rediscoverListsTheDaysAlbumsTracksInItsOrderUnderItsPanel() async throws {
    let calls = RediscoverCalls()
    let (browser, window, ids) = try await rediscoverBrowser(calls: calls)
    defer { window.orderOut(nil) }
    browser.showRediscover()
    try await waitForTheDay(browser, ids)
    #expect(browser.shownPanel === browser.rediscoverPanel)
    #expect(calls.calls.first == "send profile")
    #expect(browser.model.sortColumn == .playlistOrder && browser.model.ascending)
    let albums = try await browser.reader.albumIDs(ids: browser.model.trackIDs)
    let order = browser.model.trackIDs.compactMap { albums[$0] }
    #expect(order.first == ids[0] && order.last == ids[1])
    #expect(Set(order) == Set(ids))
    // Selecting a track shows its album's reasons.
    let last = browser.model.trackIDs.count - 1
    browser.table.table.selectRowIndexes([last], byExtendingSelection: false)
    try await waitFor("the reasons") { browser.rediscover.selectedAlbumID == ids[1] }
    #expect(browser.rediscoverPanel.reasonsText.stringValue.contains("Never played"))
    #expect(browser.sidebarController.selectedSource == .rediscover)
}

@MainActor @Test func showRediscoverInSidebarOffLeavesOutItsRowButNotTheSource() async throws {
    let calls = RediscoverCalls()
    let (browser, window, ids) = try await rediscoverBrowser(calls: calls)
    defer { window.orderOut(nil) }
    let outline = browser.sidebarController.outline
    let rows = outline.numberOfRows
    browser.showsRediscoverInSidebar = false
    #expect(outline.numberOfRows == rows - 1)
    browser.showRediscover()
    try await waitForTheDay(browser, ids)
    #expect(outline.selectedRow == -1, "no row selected for it")
    browser.showsRediscoverInSidebar = true
    #expect(outline.numberOfRows == rows)
    #expect(browser.sidebarController.selectedSource == .rediscover)
}
