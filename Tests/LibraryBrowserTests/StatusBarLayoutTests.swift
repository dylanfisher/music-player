import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

private func column(
    _ parts: [StatusPart], _ alignment: BarAlignment = .center, stacks: Bool = false
) -> BarColumn<StatusPart> {
    BarColumn(parts: parts, width: .flexible, alignment: alignment, stacks: stacks)
}

@Test func theSeekBarOrElseTheTotalsTakeTheFreeWidthOfTheirColumn() {
    let layout = StatusBarLayout(
        columns: BarLayout(
            leading: [column([.art, .seek, .totals])], center: column([.track, .format]),
            trailing: [column([.format])]),
        style: .minimal)
    #expect(layout.stretching(at: .leading(0)) == .seek)
    // The totals' label still has a place in the center, for a failure.
    #expect(layout.parts(at: .center) == [.track, .format])
    #expect(layout.stretching(at: .center) == nil)
    #expect(layout.showsTotals)
    let noTotals = StatusBarLayout(
        columns: BarLayout(center: column([.track]), trailing: [column([.seek])]),
        style: .minimal)
    #expect(!noTotals.showsTotals)
    #expect(noTotals.parts(at: .center) == [.track, .totals])
    #expect(noTotals.stretching(at: .center) == .totals)
    #expect(noTotals.parts(at: .trailing(0)) == [.seek])
}

@Test func theMinimalBarMatchesTheHeaderAndTheTallOneGrowsToItsStacks() {
    let stacked = BarLayout(center: column([.track, .format], stacks: true))
    let minimal = StatusBarLayout(columns: stacked, style: .minimal)
    #expect(!minimal.stacks(at: .center))
    #expect(minimal.heightPoints(headerPoints: 24, stackPoints: 60) == 24)
    #expect(minimal.artPoints(heightPoints: 24) == 24 - 2 * StatusBarLayout.artInsetPoints)
    let tall = StatusBarLayout(columns: stacked, style: .tall)
    #expect(tall.stacks(at: .center))
    #expect(tall.heightPoints(headerPoints: 24) == StatusBarStyle.tallPoints)
    #expect(tall.heightPoints(headerPoints: 60) == 60)
    #expect(tall.heightPoints(headerPoints: 24, stackPoints: 50) == 50 + 6)
    #expect(tall.heightPoints(headerPoints: 24, stackPoints: 500) == StatusBarStyle.tallMaxPoints)
}

@MainActor @Test func theColumnsHoldTheirPartsAndAFailureShowsWithoutTotals() throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    _ = browser.content.view
    let art = NSView()
    let seek = NSView()
    let track = NSView()
    browser.setStatusBar(
        StatusBarLayout(
            columns: BarLayout(
                leading: [column([.art])], center: column([.seek, .totals], .trailing),
                trailing: [column([.track])]),
            style: .tall),
        views: [.art: art, .seek: seek, .track: track])
    #expect(browser.statusColumn(at: .leading(0))?.stack.arrangedSubviews == [art])
    #expect(
        browser.statusColumn(at: .center)?.stack.arrangedSubviews == [seek, browser.statusLabel])
    #expect(browser.statusColumn(at: .trailing(0))?.stack.arrangedSubviews == [track])
    #expect(browser.statusColumn(at: .trailing(1)) == nil)
    #expect(browser.statusLabel.alignment == .right)
    #expect(!browser.statusLabel.isHidden)

    browser.setStatusBar(
        StatusBarLayout(columns: BarLayout(center: column([.art])), style: .minimal),
        views: [.art: art])
    #expect(
        browser.statusColumn(at: .center)?.stack.arrangedSubviews == [art, browser.statusLabel])
    #expect(browser.statusColumn(at: .leading(0)) == nil)
    // The side columns let go of their parts.
    #expect(track.superview == nil)
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
    let layout = BarLayout(center: column([.art]))
    browser.setStatusBar(StatusBarLayout(columns: layout, style: .minimal), views: [.art: art])
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
    browser.setStatusBar(StatusBarLayout(columns: layout, style: .tall), views: [.art: art])
    #expect(art.gestureRecognizers.count == 1)
}
