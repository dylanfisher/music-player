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
        failed: { Issue.record("\($0)") }, keyCommand: { _ in .unbound })
    let controller = TrackTableController(
        model: model, cache: RowCache { try index.rows(ids: $0) },
        layout: AppState().trackTable.defaultValue, actions: actions)
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

@MainActor @Test func theReportedLayoutAlwaysPassesSettingsChecks() throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, sort: { _, _ in }, layoutChanged: { _ in },
        failed: { _ in }, keyCommand: { _ in .unbound })
    let controller = TrackTableController(
        model: model, cache: RowCache { _ in [] }, layout: AppState().trackTable.defaultValue,
        actions: actions)
    _ = controller.view
    controller.table.tableColumns[0].width = 9000
    controller.table.tableColumns[1].width = 1
    #expect(controller.layout.problem() == nil)
}

@MainActor @Test func keysMoveTheSelectionFromTheCursor() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true)
    let index = try LibraryIndex(at: databaseURL)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, sort: { _, _ in }, layoutChanged: { _ in },
        failed: { Issue.record("\($0)") }, keyCommand: { _ in .unbound })
    let controller = TrackTableController(
        model: model, cache: RowCache { try index.rows(ids: $0) },
        layout: AppState().trackTable.defaultValue, actions: actions)
    _ = controller.view
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))

    controller.move(.down, extending: false)
    #expect(controller.table.selectedRowIndexes == [0])
    controller.move(.down, extending: true)
    controller.move(.down, extending: true)
    #expect(controller.table.selectedRowIndexes == [0, 1, 2])
    controller.move(.last, extending: false)
    #expect(controller.table.selectedRowIndexes == [model.trackIDs.count - 1])
}

@MainActor @Test func trackNamesFollowTheTablesOrder() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .title, ascending: false)
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    let names = try await model.trackNames()
    #expect(names.map(\.id) == model.trackIDs)
}

/// A sort that lands while the names are read makes them stale; they're read again.
@MainActor @Test func trackNamesReadAgainWhenTheListChangesMeanwhile() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .title, ascending: false)
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    async let sorted: Void = model.setSort(.artist, ascending: true)
    async let read = { @MainActor in (try await model.trackNames(), model.trackIDs) }()
    let (names, shown) = try await read
    await sorted
    #expect(names.map(\.id) == shown)
}
