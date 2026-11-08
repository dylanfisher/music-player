import AppKit
import Fixtures
import Foundation
import Testing

@testable import Settings
@testable import SettingsWindow

private let home = NSHomeDirectory()
private let newest = LibraryDatabase.Snapshot(
    path: "/tmp/Backups/library-2026-11-08.sqlite.gz", day: "2026-11-08",
    written: Date(timeIntervalSince1970: 1_794_000_000), bytes: 4_200_000)
private let older = LibraryDatabase.Snapshot(
    path: "/tmp/Backups/library-2026-11-07.sqlite.gz", day: "2026-11-07",
    written: Date(timeIntervalSince1970: 1_793_900_000), bytes: 4_100_000)
private let database = LibraryDatabase(
    indexPath: home + "/Library/Application Support/MusicPlayer/library.sqlite",
    indexBytes: 25_000_000, snapshots: [newest, older], lastFailure: nil)

@Test func theLastSnapshotRowSaysWhenOrWhyNot() {
    #expect(database.lastSnapshotText == LibraryDatabase.writtenText(newest.written))
    var none = database
    none.snapshots = []
    #expect(none.lastSnapshotText == "None yet")
    var failed = database
    failed.lastFailure = "the disk is full"
    #expect(failed.lastSnapshotText == "Last snapshot failed: the disk is full")
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
            chooseSyncFolder: {}, openSyncFolder: {}, addFolder: {}, removeFolder: { _ in },
            rescanNow: {}, rescanFolders: { _ in }, outputs: { [] }, searchOutputs: {},
            chooseOutput: { _ in }, showHealth: {}, libraryDatabase: { database },
            revealIndex: revealIndex, backUpNow: backUpNow, restoreSnapshot: restore))
}

@MainActor @Test func theLibrarySectionShowsTheIndexAndItsSnapshots() async throws {
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
    let deadline = Date().addingTimeInterval(10)
    while pane.backUpButton?.isEnabled != true, Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(backedUp == 1)
    #expect(pane.backUpButton?.isEnabled == true)
}

@MainActor @Test func theSnapshotFolderDefaultsToBackupsBesideTheLibrary() throws {
    let pane = settingsPane()
    _ = pane.view
    func labels(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels)
    }
    #expect(labels(pane.view).contains("Backups, beside the library"))
}
