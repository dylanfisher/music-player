import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser
@testable import Recommender

/// A browser over a copy of the shared library in a window, the first three of its albums
/// tagged with a release each, whose Threads asks a stand-in service that connects each of
/// those to the other two, keyed and titled as this Mac's profile has them; the seeds asked,
/// and the three albums by id.
@MainActor
private func threadsBrowser() async throws -> (LibraryBrowser, NSWindow, ThreadsAsked, [Int64]) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let albums = try index.libraryProfile().albums
    let tagged = Array(albums.compactMap { albumID(profileKey: $0.key) }.prefix(3))
    for id in tagged {
        try index.database.prepare("UPDATE tracks SET discogs_release_id = ? WHERE album_id = ?")
            .run(String(id + 1000), id)
    }
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
    let titles = Dictionary(uniqueKeysWithValues: albums.map { ($0.key, $0.title) })
    func album(_ id: Int64) -> RediscoverDay.Album {
        var album = rediscovered(profileKey(albumID: id))
        album.title = titles[album.key]!
        album.score = nil
        album.reasons = []
        return album
    }
    let made = Dictionary(uniqueKeysWithValues: tagged.map { ($0, album($0)) })
    let asked = ThreadsAsked()
    browser.threadsService = {
        ThreadsService(threads: { key throws(RecommenderError) in
            await MainActor.run {
                asked.keys.append(key)
                let seed = albumID(profileKey: key)!
                let others = tagged.filter { $0 != seed }.compactMap { made[$0] }
                return AlbumThreads(
                    seed: made[seed]!, computedAt: 1_800_000_000, albums: others,
                    threads: [
                        RediscoverDay.Thread(
                            kind: .label, words: "Seed Records", ids: others.map(\.id),
                            artist: nil, label: nil)
                    ])
            }
        })
    }
    browser.sendProfile = { _ in .unchanged }
    return (browser, window, asked, tagged)
}

/// The seeds the stand-in service was asked for.
@MainActor
private final class ThreadsAsked {
    var keys: [String] = []
}

/// Selects the first track of album `id` in the table, and waits for its seed to be read.
@MainActor
private func select(album id: Int64, in browser: LibraryBrowser) async throws {
    let albums = try await browser.reader.albumIDs(ids: browser.model.trackIDs)
    let track = try #require(browser.model.trackIDs.first { albums[$0] == id })
    browser.table.table.selectRowIndexes(
        browser.model.rows(holding: [track]), byExtendingSelection: false)
    await browser.selectionSeedRead?.value
}

/// Waits until Threads shows the seed `seed` over a table of the other albums of `all`.
@MainActor
private func waitForThreads(of seed: Int64, _ all: [Int64], in browser: LibraryBrowser)
    async throws
{
    try await waitFor("the threads of \(seed)") {
        let tracks = browser.model.trackIDs
        guard browser.model.filter.source == .threads, browser.model.filter.threadsSeed == seed,
            browser.threads.seed == seed, browser.threads.reply != nil, !tracks.isEmpty
        else { return false }
        let albums = try await browser.reader.albumIDs(ids: tracks)
        return Set(tracks.compactMap { albums[$0] }) == Set(all.filter { $0 != seed })
    }
}

@MainActor @Test func showThreadsIsOnlyForOneAlbumWithOneReleaseOnEveryTrack() async throws {
    let (browser, window, _, tagged) = try await threadsBrowser()
    defer { window.orderOut(nil) }
    var beeps = 0
    browser.beep = { beeps += 1 }
    #expect(!browser.canShowThreads, "nothing selected")
    browser.showThreadsOfSelection()
    #expect(beeps == 1)
    try await select(album: tagged[0], in: browser)
    #expect(browser.canShowThreads)
    let albums = try await browser.reader.albumIDs(ids: browser.model.trackIDs)
    let untagged = try #require(
        browser.model.trackIDs.first { albums[$0].map(tagged.contains) == false })
    browser.table.table.selectRowIndexes(
        browser.model.rows(holding: [untagged]), byExtendingSelection: false)
    #expect(!browser.canShowThreads, "off until the selection is read")
    await browser.selectionSeedRead?.value
    #expect(!browser.canShowThreads, "an untagged album")
    let two = try tagged.prefix(2).map { id in
        try #require(browser.model.trackIDs.first { albums[$0] == id })
    }
    browser.table.table.selectRowIndexes(
        browser.model.rows(holding: Set(two)), byExtendingSelection: false)
    await browser.selectionSeedRead?.value
    #expect(!browser.canShowThreads, "two albums")
}

@MainActor @Test func backAndForwardWalkTheSeeds() async throws {
    let (browser, window, asked, tagged) = try await threadsBrowser()
    defer { window.orderOut(nil) }
    try await select(album: tagged[0], in: browser)
    browser.showThreadsOfSelection()
    try await waitForThreads(of: tagged[0], tagged, in: browser)
    #expect(browser.shownPanel === browser.threadsPanel)
    #expect(browser.model.sortColumn == .playlistOrder && browser.model.ascending)
    #expect(browser.sidebarController.selectedSource == .threads)
    #expect(browser.threadsPanel.threadsList.rows.map(\.name) == ["All", "Seed Records"])
    // Each next seed is one of the source's own albums.
    for seed in tagged.dropFirst() {
        try await select(album: seed, in: browser)
        try await waitFor("the album's threads") {
            browser.threadsPanel.albumText.stringValue.contains("Seed Records")
        }
        browser.showThreadsOfSelection()
        try await waitForThreads(of: seed, tagged, in: browser)
    }
    for seed in [tagged[1], tagged[0]] {
        browser.back()
        try await waitForThreads(of: seed, tagged, in: browser)
    }
    browser.back()
    try await waitFor("the library") { browser.model.filter.source == nil }
    browser.forward()
    try await waitForThreads(of: tagged[0], tagged, in: browser)
    // Each seed is asked for as it shows, the last as Threads opens again.
    try await waitFor("the asks") { asked.keys.count == 6 }
    #expect(asked.keys == [0, 1, 2, 1, 0, 0].map { profileKey(albumID: tagged[$0]) })
}

@MainActor @Test func threadsWithoutASeedSaysToChooseShowThreads() async throws {
    let (browser, window, asked, _) = try await threadsBrowser()
    defer { window.orderOut(nil) }
    let outline = browser.sidebarController.outline
    let rows = outline.numberOfRows
    browser.showsThreadsInSidebar = false
    #expect(outline.numberOfRows == rows - 1)
    browser.show(.threads)
    try await waitFor("Threads") { browser.shownPanel === browser.threadsPanel }
    #expect(browser.threadsPanel.problemText.stringValue == threadsNoSeedText)
    #expect(outline.selectedRow == -1, "no row selected for it")
    browser.showsThreadsInSidebar = true
    #expect(outline.numberOfRows == rows)
    #expect(browser.sidebarController.selectedSource == .threads)
    #expect(asked.keys.isEmpty)
}
