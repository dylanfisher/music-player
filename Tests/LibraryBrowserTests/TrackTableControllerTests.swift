import AppKit
import Library
import Settings
import Testing

@testable import LibraryBrowser

@MainActor @Test func aReSortKeepsTheSameTracksSelected() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true)
    let index = try LibraryIndex(at: databaseURL)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, sort: { _, _ in }, layoutChanged: { _ in },
        failed: { Issue.record("\($0)") })
    let controller = TrackTableController(
        model: model, cache: RowCache { try index.rows(ids: $0) },
        layout: AppSettings().trackTable.defaultValue, actions: actions)
    _ = controller.view
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))

    controller.table.selectRowIndexes([2, 7], byExtendingSelection: false)
    let picked = Set([2, 7].map { model.trackIDs[$0] })
    await model.setSort(.title, ascending: false)
    let selected = Set(controller.table.selectedRowIndexes.map { model.trackIDs[$0] })
    #expect(selected == picked)
    #expect(controller.table.selectedRowIndexes != [2, 7])
}
