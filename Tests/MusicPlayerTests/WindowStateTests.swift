import AppKit
import Foundation
import Testing

@testable import Library
@testable import LibraryBrowser
@testable import MusicPlayer
@testable import Settings

/// The browser's split of its columns over the track table.
@MainActor
private func horizontalSplit(_ view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView, !split.isVertical { return split }
    return view.subviews.lazy.compactMap(horizontalSplit).first
}

/// Everything the window shows, changed, saved as the app saves it while it runs and as it
/// quits, then read by a second window on the same state and config, as a relaunch does.
@MainActor @Test func everythingTheWindowShowsComesBackAfterAQuit() async throws {
    let databaseURL = try writableWindowLibrary()
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("window-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let first = try await MainWindowFixture(
        home: home, databaseURL: databaseURL, fillsWindow: true)
    let browser = first.browser
    let model = browser.model

    // The window's frame, the queue shown, and the sidebar and queue widths.
    let frame = NSRect(x: 60, y: 80, width: 1180, height: 520)
    first.window.window.setFrame(frame, display: false)
    first.window.toggleQueue()
    first.window.window.layoutIfNeeded()
    let split = try #require(first.window.window.contentView.flatMap(firstVerticalSplit))
    split.setPosition(240, ofDividerAt: 0)
    split.setPosition(split.bounds.width - 300, ofDividerAt: 1)
    // The browser's columns taller. Stats has a height of its own, whose divider shows only
    // with Stats, so it's reported as a drag of that divider reports it.
    let panes = try #require(browser.content.view.subviews.lazy.compactMap(horizontalSplit).first)
    panes.setPosition(200, ofDividerAt: 0)
    browser.statsHeightChanged(300)

    // The table sorted by Year, newest first, and the Artist column wider.
    await model.setSort(.year, ascending: false)
    let artist = NSUserInterfaceItemIdentifier(TrackColumn.artist.rawValue)
    try #require(browser.table.table.tableColumn(withIdentifier: artist)).width = 260

    // A playlist of every track shown, sorted by title in it.
    let index = try LibraryIndex(at: databaseURL)
    let playlist = try index.createPlaylist(named: "Evening")
    _ = try index.addToPlaylist(playlist, trackIDs: model.trackIDs)
    try await model.reloadPlaylists()
    await model.setSource(.playlist(playlist))
    await model.setSort(.title, ascending: true)

    // The genre with the most tracks selected, and its name searched for, which matches the
    // same tracks, so enough rows are left to scroll.
    var most: (value: BrowserValue, name: String, count: Int)?
    for entry in model.entries[0] where entry.name.allSatisfy(\.isLetter) {
        await model.select(.genres, entry.value)
        if model.trackIDs.count > most?.count ?? 0 {
            most = (entry.value, entry.name, model.trackIDs.count)
        }
    }
    let genre = try #require(most)
    await model.select(.genres, genre.value)
    browser.searchField.stringValue = genre.name
    await model.setSearch(browser.searchField.stringValue)
    #expect(model.trackIDs.count == genre.count)

    // The last row selected, and the list scrolled down.
    let rows = model.trackIDs.count
    browser.table.select([rows - 1])
    browser.table.scroll(toRow: rows / 2)
    let selected = model.trackIDs[rows - 1]
    let top = try #require(browser.listPlace().scroll?.id)
    #expect(top != model.trackIDs[0], "the list scrolled")
    let shown = model.trackIDs
    // The sidebar and queue as they are at the quit, after the table's changes laid them out.
    let quitWidths = split.arrangedSubviews.map { $0.frame.width }
    #expect(quitWidths[0] != 180 && quitWidths[2] != 220, "not the default widths")
    let selections = model.filter.selections

    // Quitting writes what's pending and the play state.
    first.saver.flush()
    try first.settings.set(\.resume, to: try #require(browser.resumePoint(playing: nil)))
    first.close()

    let second = try await MainWindowFixture(
        home: home, databaseURL: databaseURL, fillsWindow: true)
    defer { second.close() }
    let again = second.browser
    #expect(again.model.filter.source == .playlist(playlist))
    #expect(again.model.sortColumn == .title && again.model.ascending)
    #expect(again.model.tableSort == (.year, false))
    #expect(again.table.table.tableColumn(withIdentifier: artist)?.width == 260)
    #expect(again.model.filter.selections == selections)
    #expect(again.searchField.stringValue == genre.name)
    #expect(again.model.trackIDs == shown)
    #expect(Set(again.model.ids(ofRows: again.table.table.selectedRowIndexes)) == [selected])
    #expect(again.listPlace().scroll?.id == top)
    #expect(again.slotHeight == 200)
    #expect(again.statsHeight == 300)
    #expect(second.window.isQueueVisible)
    let widths = try #require(second.window.window.contentView.flatMap(firstVerticalSplit))
        .arrangedSubviews.map { $0.frame.width }
    #expect(widths[0] == quitWidths[0] && widths[2] == quitWidths[2])
    #expect(second.window.window.frame == frame)
}

/// A library refresh that changes nothing, as during a scan, reports the browser's state again
/// and leaves the state file as it was.
@MainActor @Test func aRefreshThatChangesNothingWritesNoState() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    await fixture.browser.model.setSearch("a")
    fixture.saver.flush()
    let path = fixture.state.fileURL.path
    let written = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]
    var reported = 0
    let stateChanged = fixture.browser.stateChanged
    fixture.browser.stateChanged = {
        reported += 1
        stateChanged($0)
    }
    await fixture.browser.model.refresh()
    fixture.saver.flush()
    #expect(reported > 0)
    let after = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]
    // An atomic write replaces the file, so a write gives it a new file number.
    #expect(after as? Int == written as? Int)
}
