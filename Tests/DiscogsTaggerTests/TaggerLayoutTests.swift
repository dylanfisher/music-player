import AppKit
import Foundation
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Settings

/// The owner's report (69): the album list's widths are gone at the next launch. Nothing
/// recorded them. Now a first tagger's saved layouts open a second one at the album pane's
/// width and the columns' widths, as a relaunch reads them from the state file.
@MainActor
@Test func theAlbumListsWidthsComeBackInANewWindow() async throws {
    let made = await model(
        Seen(), albums: [], matches: { album, _ in match(album, nil, tier: .noCandidate) })
    let first = DiscogsTagger(model: made)
    var saved = TaggerSheetLayouts()
    first.sheetLayoutsChosen = { saved = $0 }
    first.show()
    let controller = try #require(first.window?.windowController as? TaggerWindow)
    let window = try #require(first.window)
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.contentView?.layoutSubtreeIfNeeded()
    let split = try #require(controller.albumTable.enclosingScrollView?.superview as? NSSplitView)
    split.setPosition(460, ofDividerAt: 0)
    window.contentView?.layoutSubtreeIfNeeded()
    // As a drag of a column's edge leaves them: the others take up the difference.
    controller.albumTable.tableColumns[1].width = 90
    controller.albumTable.sizeToFit()
    let widths = controller.albumTable.tableColumns.map(\.width)
    let pane = try #require(controller.albumTable.enclosingScrollView).frame.width
    #expect(saved.albumList?.paneWidth == Double(pane))
    #expect(saved.albumList?.table.widths["files"] == 90)
    window.close()

    let second = DiscogsTagger(model: made)
    second.sheetLayouts = saved
    second.show()
    let reopened = try #require(second.window?.windowController as? TaggerWindow)
    reopened.window?.contentView?.layoutSubtreeIfNeeded()
    let reopenedPane = try #require(reopened.albumTable.enclosingScrollView).frame.width
    #expect(reopenedPane == pane)
    #expect(reopened.albumTable.tableColumns.map(\.width) == widths)
    second.window?.close()
}

/// A click on an album list's header sorts by it and a second reverses it, as setting the
/// table's descriptors does; the sort is saved and a new window opens with it (69).
@MainActor
@Test func theAlbumListSortsByAHeaderClickAndKeepsTheSort() async throws {
    let albums = [
        album(1, "Stockholm", titles: ["A", "B", "C"]),
        album(2, "Second", artist: "Abba", titles: ["A"]),
    ]
    let made = await model(
        Seen(), albums: albums,
        matches: { album, _ in
            match(album, release(Int(album.id), album.title, titles: ["A"]), tier: .exact)
        })
    made.analyze()
    await made.finished()
    let first = DiscogsTagger(model: made)
    var saved = TaggerSheetLayouts()
    first.sheetLayoutsChosen = { saved = $0 }
    first.show()
    let controller = try #require(first.window?.windowController as? TaggerWindow)
    #expect(controller.shownAlbums.map(\.id) == [2, 1])
    let files = try #require(controller.albumTable.tableColumns[1].sortDescriptorPrototype)
    let mostFirst = NSSortDescriptor(key: "files", ascending: false)
    controller.albumTable.sortDescriptors = [mostFirst]
    #expect(controller.shownAlbums.map(\.id) == [1, 2], "the most files first")
    controller.albumTable.sortDescriptors = [files]
    #expect(controller.shownAlbums.map(\.id) == [2, 1])
    controller.albumTable.sortDescriptors = [mostFirst]
    #expect(saved.albumList?.table.sortColumn == "files")
    #expect(saved.albumList?.table.sortAscending == false)
    first.window?.close()

    made.sortAlbums(by: nil)
    let second = DiscogsTagger(model: made)
    second.sheetLayouts = saved
    second.show()
    let reopened = try #require(second.window?.windowController as? TaggerWindow)
    #expect(reopened.albumTable.sortDescriptors == [mostFirst])
    #expect(reopened.shownAlbums.map(\.id) == [1, 2])
    second.window?.close()
}
