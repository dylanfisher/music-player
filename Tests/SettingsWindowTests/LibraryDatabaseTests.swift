import AppKit
import Commands
import Foundation
import Testing

@testable import Fixtures
@testable import Settings
@testable import SettingsWindow

private let home = NSHomeDirectory()
private let newest = LibraryDatabase.Snapshot(
    path: "/tmp/Backups/library-2026-11-08.sqlite.gz", day: "2026-11-08",
    written: Date(timeIntervalSince1970: 1_794_000_000), bytes: 4_200_000, beforeRestore: true)
private let older = LibraryDatabase.Snapshot(
    path: "/tmp/Backups/library-2026-11-07.sqlite.gz", day: "2026-11-07",
    written: Date(timeIntervalSince1970: 1_793_900_000), bytes: 4_100_000, beforeRestore: false)
private let database = LibraryDatabase(
    indexPath: home + "/Library/Application Support/MusicPlayer/library.sqlite",
    indexBytes: 25_000_000, snapshots: [newest, older], lastProblem: nil)

@Test func theLastSnapshotRowSaysWhenOrWhyNot() {
    #expect(database.lastSnapshotText == LibraryDatabase.writtenText(newest.written))
    var none = database
    none.snapshots = []
    #expect(none.lastSnapshotText == "None yet")
    var failed = database
    failed.lastProblem = "The last snapshot failed: the disk is full"
    #expect(failed.lastSnapshotText == "The last snapshot failed: the disk is full")
    #expect(database.pathText == "~/Library/Application Support/MusicPlayer/library.sqlite")
    #expect(
        database.sizeText
            == ByteCountFormatter.string(fromByteCount: 25_000_000, countStyle: .file))
}

@MainActor
private func settingsPane(
    backUpNow: @escaping () async -> Void = {}, revealIndex: @escaping () -> Void = {},
    restore: @escaping (LibraryDatabase.Snapshot) -> Void = { _ in }
) -> GeneralPane {
    let schema = AppSettings()
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { _ in nil }, set: { _, _ in },
        isBlocked: { false })
    return GeneralPane(
        model: model, configPath: "/tmp/config.json",
        actions: SettingsActions(
            openConfigFile: {}, revealConfigFile: {}, copyDefaultConfig: {},
            chooseSyncFolder: {}, openSyncFolder: {}, chooseStagingFolder: {}, addFolder: {},
            removeFolder: { _ in },
            rescanNow: {}, rescanFolders: { _ in }, outputs: { [] }, searchOutputs: {},
            chooseOutput: { _ in }, showHealth: {}, libraryDatabase: { database },
            revealIndex: revealIndex, backUpNow: backUpNow, restoreSnapshot: restore))
}

@MainActor @Test func theDatabaseSectionShowsTheIndexAndItsSnapshots() async throws {
    var revealed = 0
    var restored: [LibraryDatabase.Snapshot] = []
    var backedUp = 0
    let pane = settingsPane(
        backUpNow: { backedUp += 1 }, revealIndex: { revealed += 1 },
        restore: { restored.append($0) })
    _ = pane.view
    await pane.showDatabase()
    let path = try #require(pane.indexPathLabel)
    #expect(path.stringValue == database.pathText)
    #expect(pane.indexSizeLabel?.stringValue == database.sizeText)
    #expect(pane.lastSnapshotLabel?.stringValue == database.lastSnapshotText)

    // The index's Reveal in Finder is on its row, beside the size.
    let reveal = try #require((path.superview as? NSStackView)?.arrangedSubviews.last as? NSButton)
    click(reveal)
    #expect(revealed == 1)

    let list = try #require(pane.snapshotList)
    #expect(list.table.numberOfRows == 2)
    let restore = try #require(pane.restoreButton)
    #expect(!restore.isEnabled)
    list.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(restore.isEnabled)
    click(restore)
    #expect(restored == [older])

    click(try #require(pane.backUpButton))
    #expect(pane.backUpButton?.isEnabled == false)
    let deadline = Date().addingTimeInterval(waitLimit)
    while pane.backUpButton?.isEnabled != true, Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(backedUp == 1)
    #expect(pane.backUpButton?.isEnabled == true)
}

/// The snapshot list always shows, short, under Last Snapshot and Back Up Now, with no
/// disclosure to open (phase 70).
@MainActor @Test func theSnapshotListAlwaysShows() async throws {
    let pane = settingsPane()
    _ = pane.view
    await pane.showDatabase()
    #expect(pane.lastSnapshotLabel?.stringValue == database.lastSnapshotText)
    let list = try #require(pane.snapshotList)
    #expect(list.table.numberOfRows == 2)
    let grid = try #require(
        sequence(first: list.scroll as NSView, next: \.superview).compactMap { $0 as? NSGridView }
            .first)
    let rows = (0..<grid.numberOfRows).map(grid.row(at:))
    let listRow = try #require(
        rows.first { row in
            (0..<row.numberOfCells).contains {
                row.cell(at: $0).contentView?.subviews.contains(list.scroll) == true
            }
        })
    #expect(!listRow.isHidden)
    #expect(
        !pane.disclosures.values.contains { triangle in
            sequence(first: triangle as NSView, next: \.superview).contains { $0 === grid }
        }, "no disclosure in the Database box")
}

@MainActor @Test func theSnapshotFolderDefaultsToBackupsBesideTheLibrary() throws {
    let pane = settingsPane()
    _ = pane.view
    func labels(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels)
    }
    #expect(labels(pane.view).contains("Backups, beside the library"))
}

/// The pane ends with two boxes: Browsing, then Database, which has the index above the
/// Snapshot Folder row and that above the snapshots.
@MainActor @Test func theBrowsingBoxComesBeforeTheDatabaseBoxWithItsRowsInOrder() throws {
    let pane = settingsPane()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 2000), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentViewController = pane
    window.layoutIfNeeded()
    let schema = AppSettings()
    let expected = [
        "Browsing", schema.groupByAlbumArtist.title, schema.separateReleases.title,
        schema.fileViewer.title + ":", AppCommands.title(of: .checkHealth), "Database",
        "Database:", schema.snapshotFolder.title + ":", "Last Snapshot:", "Snapshots:",
    ]
    func texts(_ view: NSView) -> [(String, CGFloat)] {
        let own = (view as? NSTextField).map {
            [($0.stringValue, view.convert(view.bounds, to: nil).maxY)]
        }
        let button = (view as? NSButton).map {
            [($0.title, view.convert(view.bounds, to: nil).maxY)]
        }
        return (own ?? []) + (button ?? []) + view.subviews.flatMap(texts)
    }
    let found = texts(pane.view).filter { expected.contains($0.0) }.sorted { $0.1 > $1.1 }
    #expect(found.map { $0.0 } == expected)
}

@Test func aSnapshotBeforeARestoreSaysSo() {
    #expect(newest.takenText == LibraryDatabase.writtenText(newest.written) + " (before a restore)")
    #expect(older.takenText == LibraryDatabase.writtenText(older.written))
}

/// Opening and closing a disclosure leaves the pane's top at the window's top: the window is
/// resized after the layout pass that changed the pane's height, not inside it, which left the
/// scroll view at its old height plus the change and an empty strip above it.
@MainActor @Test func closingADisclosureLeavesNoGapAtTheTop() async throws {
    let pane = settingsPane()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scroller = PaneScroller(pane)
    scroller.visibleFrame = { _ in nil }
    window.contentViewController = scroller
    await pane.showDatabase()
    func settle() async throws {
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        window.layoutIfNeeded()
    }
    func expectPaneFillsTheWindow(_ when: Comment) {
        let content = window.contentLayoutRect
        let top = pane.view.convert(
            NSPoint(x: 0, y: pane.view.isFlipped ? 0 : pane.view.bounds.maxY), to: nil)
        #expect(scroller.view.frame.height == content.height, when)
        #expect(top.y == content.maxY, when)
        #expect(pane.view.frame.height == content.height, when)
    }
    try await settle()
    expectPaneFillsTheWindow("at first")
    let triangle = try #require(pane.disclosures[AppSettings().receiverAddress.key])
    click(triangle)
    try await settle()
    expectPaneFillsTheWindow("opened")
    click(triangle)
    try await settle()
    expectPaneFillsTheWindow("closed")
}
