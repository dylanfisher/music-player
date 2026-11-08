import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

// A drag of rows hands other apps the files, a copy only, and drops in the app as tracks, as
// before (53.2, ADR 0141). The pasteboards are private ones; no file is copied anywhere.

/// A pasteboard of its own, not the drag one another drag could be using.
private func scratchPasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("track-drag-\(UUID().uuidString)"))
    pasteboard.clearContents()
    return pasteboard
}

/// A browser over a copy of the shared library, with a manual playlist "Mix" that's empty.
@MainActor
private func browser() async throws -> (LibraryBrowser, LibraryIndex) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    _ = try index.createPlaylist(named: "Mix")
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    await browser.load(BrowserState(source: nil))
    return (browser, index)
}

@MainActor @Test func aDraggedRowCarriesItsTrackIDAndItsFile() async throws {
    let (browser, index) = try await browser()
    let table = browser.table
    let rows = [3, 7]
    let items = try rows.map { row in
        try #require(
            table.tableView(table.table, pasteboardWriterForRow: row) as? NSPasteboardItem)
    }
    let pasteboard = scratchPasteboard()
    pasteboard.writeObjects(items)
    let ids = rows.map { browser.model.trackIDs[$0] }
    #expect(draggedTrackIDs(pasteboard) == ids)
    let urls = try #require(
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL])
    #expect(urls.map(\.path) == (try index.rows(ids: ids)).map(\.path))
}

@MainActor @Test func outsideTheAppADragOffersACopyOnly() async throws {
    let (browser, _) = try await browser()
    let table = browser.table.table
    #expect(table.dragOperationMask(for: .outsideApplication) == .copy)
    #expect(table.dragOperationMask(for: .withinApplication) == [.copy, .move])
    let timeline = browser.timeline.table
    #expect(timeline.dragOperationMask(for: .outsideApplication) == .copy)
    #expect(timeline.dragOperationMask(for: .withinApplication) == .copy)
}

/// A drop as AppKit hands it over: its pasteboard and where the drag came from.
@MainActor
private final class Drop: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?

    init(_ pasteboard: NSPasteboard, from source: Any?) {
        draggingPasteboard = pasteboard
        draggingSource = source
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set {}
    }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// Rows dropped on a playlist are added to it, though they carry their files; the same files
/// from another app go to the library.
@MainActor @Test func theAppsOwnRowsDropOnAPlaylistAsTracks() async throws {
    let (browser, _) = try await browser()
    let sidebar = try #require(browser.sidebar as? SidebarController)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = sidebar.view
    let mix = try #require(browser.playlists.first { $0.name == "Mix" }).id
    window.layoutIfNeeded()
    let outline = sidebar.outline
    let row = try #require(
        (0..<outline.numberOfRows).first { row in
            outline.view(atColumn: 0, row: row, makeIfNecessary: true).flatMap {
                ($0 as? NSTableCellView)?.textField?.stringValue
            } == "Mix"
        })
    let item = outline.item(atRow: row)
    var droppedTracks: [(Int64, [Int64])] = []
    var droppedFiles: [[URL]] = []
    sidebar.dropTracks = { droppedTracks.append(($0, $1)) }
    sidebar.dropFiles = { droppedFiles.append($0) }

    let table = browser.table
    let pasteboard = scratchPasteboard()
    pasteboard.writeObjects([
        try #require(table.tableView(table.table, pasteboardWriterForRow: 2) as? NSPasteboardItem)
    ])
    let ownRows = Drop(pasteboard, from: table.table)
    #expect(
        sidebar.outlineView(
            outline, validateDrop: ownRows, proposedItem: item,
            proposedChildIndex: NSOutlineViewDropOnItemIndex) == .copy)
    #expect(sidebar.outlineView(outline, acceptDrop: ownRows, item: item, childIndex: -1))
    #expect(droppedTracks.map(\.0) == [mix])
    #expect(droppedTracks.map(\.1) == [[browser.model.trackIDs[2]]])
    #expect(droppedFiles.isEmpty)

    #expect(
        sidebar.outlineView(
            outline, acceptDrop: Drop(pasteboard, from: nil), item: item, childIndex: -1))
    #expect(droppedFiles.count == 1)
    #expect(droppedTracks.count == 1)
}
