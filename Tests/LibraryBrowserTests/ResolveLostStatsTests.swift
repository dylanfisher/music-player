import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor
private func lostStatsBrowser() throws -> (LibraryBrowser, LibraryIndex) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    return (browser, index)
}

/// Resolve Lost Stats is on until a report finds none, and on again once one finds a lost
/// file.
@MainActor @Test func resolveLostStatsIsOffWhileThereAreNone() async throws {
    let (browser, index) = try lostStatsBrowser()
    #expect(browser.canResolveLostStats, "on before any report")
    await browser.health.run()
    #expect(!browser.canResolveLostStats)

    let track = try #require(
        try index.database.prepare("SELECT file_id FROM tracks ORDER BY file_id LIMIT 1")
            .map { try $0.int64(0) }.first)
    let path = try #require(try index.paths(ids: [track])[track])
    try index.recordPlay(path, at: 100)
    try index.remove([track])
    await browser.health.run()
    #expect(browser.canResolveLostStats)
}

/// With none to resolve, a sheet on the window says so, not the status bar.
@MainActor @Test func resolvingNoLostStatsSaysSoOnTheWindow() async throws {
    let (browser, _) = try lostStatsBrowser()
    let window = NSWindow()
    var told: [(String, NSWindow)] = []
    browser.tell = { message, _, over in told.append((message, over)) }
    let status = browser.statusText
    browser.resolveLostStats(over: window)
    try await waitFor("the sheet") { !told.isEmpty }
    #expect(told.map(\.0) == ["No Lost Stats to Resolve"])
    #expect(told.first?.1 === window)
    #expect(browser.statusText == status)
    #expect(browser.lostStatsSheet == nil)
}
