import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@Test func theSeekBarOrElseTheTotalsTakeTheFreeWidth() {
    let seek = StatusBarLayout(parts: [.art, .seek, .totals], style: .minimal)
    #expect(seek.flexible == .seek)
    #expect(seek.order == [.art, .seek, .totals])
    let track = StatusBarLayout(parts: [.track, .format], style: .minimal)
    #expect(track.flexible == .totals)
    // The totals' label still has a place, for a failure.
    #expect(track.order == [.track, .format, .totals])
    #expect(!track.showsTotals)
}

@Test func theMinimalBarMatchesTheHeaderAndTheTallOneIsTaller() {
    let minimal = StatusBarLayout(parts: [.art], style: .minimal)
    #expect(minimal.heightPoints(headerPoints: 24) == 24)
    #expect(minimal.artPoints(headerPoints: 24) == 24 - 2 * StatusBarLayout.artInsetPoints)
    let tall = StatusBarLayout(parts: [.art], style: .tall)
    #expect(tall.heightPoints(headerPoints: 24) == StatusBarLayout.tallPoints)
    #expect(tall.heightPoints(headerPoints: 60) == 60)
}

@MainActor @Test func theBarHoldsThePartsInTheirOrderAndShowsAFailureWithoutTotals() throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    _ = browser.content.view
    let art = NSView()
    let seek = NSView()
    browser.setStatusBar(
        StatusBarLayout(parts: [.seek, .totals, .art], style: .tall),
        views: [.art: art, .seek: seek, .track: NSView()])
    #expect(browser.statusPartsShown == [seek, browser.statusLabel, art])
    #expect(!browser.statusLabel.isHidden)

    browser.setStatusBar(StatusBarLayout(parts: [.art], style: .minimal), views: [.art: art])
    #expect(browser.statusPartsShown == [art, browser.statusLabel])
    #expect(browser.statusLabel.isHidden)
    browser.report("the disk went away")
    #expect(!browser.statusLabel.isHidden)
    #expect(browser.statusText == "the disk went away")
}

/// A click on the status bar's art opens the playing track's art in the viewer a row's art
/// opens (ADR 0084).
@MainActor @Test func theStatusBarsArtOpensTheViewer() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let index = try LibraryIndex(at: databaseURL)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100,
        groupByAlbumArtist: false, thumbnails: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = browser.content.view
    defer { window.close() }
    await browser.load(BrowserState(source: nil))
    let rows = try index.rows(ids: browser.model.trackIDs)
    let playing = try #require(rows.first { $0.art != nil })
    let art = NSImageView(image: NSImage(size: NSSize(width: 8, height: 8)))
    browser.setStatusBar(StatusBarLayout(parts: [.art], style: .minimal), views: [.art: art])
    let click = try #require(art.gestureRecognizers.first as? NSClickGestureRecognizer)
    #expect(click.target === browser)

    // Nothing playing: nothing to open.
    browser.openPlayingArt()
    #expect(browser.table.artViewer == nil)
    browser.showPlaying(path: playing.path)
    browser.openPlayingArt()
    let viewer = try #require(browser.table.artViewer)
    #expect(viewer.window.isVisible)
    viewer.close()
    // Laid out again, the art keeps its one click.
    browser.setStatusBar(StatusBarLayout(parts: [.art], style: .tall), views: [.art: art])
    #expect(art.gestureRecognizers.count == 1)
}
