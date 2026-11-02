import AppKit
import DisplayText
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor @Test func aReSortKeepsTheSameTracksSelected() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    let index = try LibraryIndex(at: databaseURL)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, move: { _, _ in },
        sort: { _, _ in },
        layoutChanged: { _ in },
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
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, move: { _, _ in },
        sort: { _, _ in },
        layoutChanged: { _ in },
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
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    let index = try LibraryIndex(at: databaseURL)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, move: { _, _ in },
        sort: { _, _ in },
        layoutChanged: { _ in },
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
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .title, ascending: false,
        groupByAlbumArtist: false)
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    let names = try await model.trackNames()
    #expect(names.map(\.id) == model.trackIDs)
}

/// Grouped by album artist, a compilation track sorts under Various Artists, so typing its track
/// artist's name lands on that artist's own album instead.
@Test func typeSelectMatchesTheArtistTheTableSortsBy() {
    let names = [
        TrackName(
            id: 1, title: "On Hits", artist: "Vladislav Delay", sortArtist: "Various Artists",
            album: "Hits", genre: nil),
        TrackName(
            id: 2, title: "On Anima", artist: "Vladislav Delay", sortArtist: "Vladislav Delay",
            album: "Anima", genre: nil),
    ]
    let texts = names.map { typeSelectText($0, sortedBy: .artist) }
    #expect(TypeSelect.firstIndex(startingWith: "vladislav", in: texts) == 1)
    #expect(TypeSelect.firstIndex(startingWith: "various", in: texts) == 0)
    #expect(typeSelectText(names[1], sortedBy: .album) == "Anima")
}

/// A sort that lands while the names are read makes them stale; they're read again.
@MainActor @Test func trackNamesReadAgainWhenTheListChangesMeanwhile() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .title, ascending: false,
        groupByAlbumArtist: false)
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    async let sorted: Void = model.setSort(.artist, ascending: true)
    async let read = { @MainActor in (try await model.trackNames(), model.trackIDs) }()
    let (names, shown) = try await read
    await sorted
    #expect(names.map(\.id) == shown)
}

@MainActor @Test func aRightClickSelectsItsRowUnlessItIsSelected() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, move: { _, _ in }, sort: { _, _ in },
        layoutChanged: { _ in },
        failed: { Issue.record("\($0)") }, keyCommand: { _ in .unbound })
    let controller = TrackTableController(
        model: model, cache: RowCache { _ in [] }, layout: AppState().trackTable.defaultValue,
        actions: actions)
    _ = controller.view
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    let table = controller.table
    table.selectRowIndexes([1, 3], byExtendingSelection: false)
    #expect(table.prepareMenu(at: 3))
    #expect(table.selectedRowIndexes == [1, 3])
    #expect(table.prepareMenu(at: 5))
    #expect(table.selectedRowIndexes == [5])
    // Below the last row there is no menu, and the selection stays.
    #expect(!table.prepareMenu(at: -1))
    #expect(table.selectedRowIndexes == [5])
}

@MainActor @Test func thePlayingTracksRowIsMarkedWhereverItSorts() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    let index = try LibraryIndex(at: databaseURL)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, move: { _, _ in },
        sort: { _, _ in },
        layoutChanged: { _ in },
        failed: { Issue.record("\($0)") }, keyCommand: { _ in .unbound })
    let controller = TrackTableController(
        model: model, cache: RowCache { try index.rows(ids: $0) },
        layout: AppState().trackTable.defaultValue, actions: actions)
    _ = controller.view
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    func marked() -> [Int] {
        (0..<model.trackIDs.count).filter {
            (controller.tableView(controller.table, rowViewForRow: $0) as? MarkedRowView)?
                .isMarked == true
        }
    }
    #expect(marked().isEmpty)

    let paths = try index.paths(ids: model.trackIDs)
    let playing = model.trackIDs[3]
    controller.playingPath = paths[playing]
    #expect(marked() == [3])
    controller.playingPath = paths[model.trackIDs[5]]
    #expect(marked() == [5])

    controller.playingPath = paths[playing]
    await model.setSort(.title, ascending: false)
    #expect(marked() == Array(model.rows(holding: [playing])))
    controller.playingPath = nil
    #expect(marked().isEmpty)
}

@MainActor @Test func theTableDrawsItsLinesAndRowsAsTheAppearanceSays() throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, move: { _, _ in },
        sort: { _, _ in },
        layoutChanged: { _ in },
        failed: { _ in }, keyCommand: { _ in .unbound })
    let controller = TrackTableController(
        model: model, cache: RowCache { _ in [] }, layout: AppState().trackTable.defaultValue,
        actions: actions)
    _ = controller.view
    let settings = AppSettings()
    let defaults = TableAppearance(
        columnLines: settings.columnLines.defaultValue, rowLines: settings.rowLines.defaultValue,
        alternatingRows: settings.alternatingRows.defaultValue,
        rowHeight: settings.rowHeight.defaultValue, artSize: settings.artSize.defaultValue)
    let before = (
        controller.table.gridStyleMask, controller.table.usesAlternatingRowBackgroundColors,
        controller.table.rowHeight
    )
    controller.apply(defaults)
    #expect(controller.table.gridStyleMask == before.0)
    #expect(controller.table.usesAlternatingRowBackgroundColors == before.1)
    #expect(controller.table.rowHeight == before.2)

    controller.apply(
        TableAppearance(
            columnLines: true, rowLines: true, alternatingRows: false, rowHeight: .compact,
            artSize: .thumbnail))
    #expect(
        controller.table.gridStyleMask == [
            .solidVerticalGridLineMask, .solidHorizontalGridLineMask,
        ])
    #expect(!controller.table.usesAlternatingRowBackgroundColors)
    #expect(controller.table.rowHeight == 17)
    controller.apply(
        TableAppearance(
            columnLines: true, rowLines: false, alternatingRows: true, rowHeight: .large,
            artSize: .thumbnail))
    #expect(controller.table.gridStyleMask == .solidVerticalGridLineMask)
    #expect(controller.table.rowHeight > RowListController.rowHeight)
}

@MainActor @Test func fullWidthArtDrawsEachAlbumOnceFromItsFirstRow() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .album, ascending: true,
        groupByAlbumArtist: false)
    let index = try LibraryIndex(at: databaseURL)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, move: { _, _ in },
        sort: { _, _ in },
        layoutChanged: { _ in },
        failed: { Issue.record("\($0)") }, keyCommand: { _ in .unbound })
    // Art 3 rows tall, which with its inset above reaches into a fourth row.
    let width = 2 * AlbumArtCell.inset + 3 * RowListController.rowHeight
    let controller = TrackTableController(
        model: model, cache: RowCache { try index.rows(ids: $0) },
        layout: TrackTableLayout(
            columns: [
                ColumnLayout(column: .art, width: width), ColumnLayout(column: .title, width: 200),
            ],
            sortColumn: .album, sortAscending: true),
        actions: actions)
    controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 2000)
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    let rows = try index.rows(ids: model.trackIDs)
    let art = controller.table.column(withIdentifier: NSUserInterfaceItemIdentifier("art"))
    #expect(controller.table.view(atColumn: art, row: 0, makeIfNecessary: true) is NSTableCellView)
    #expect(controller.artRow(5) == 5)

    controller.apply(
        TableAppearance(
            columnLines: false, rowLines: false, alternatingRows: true, rowHeight: .regular,
            artSize: .fullWidth))
    var runStart = 0
    var spanned = false
    for row in 0..<min(rows.count, 60) {
        if row > 0, rows[row].albumID == nil || rows[row].albumID != rows[row - 1].albumID {
            runStart = row
        }
        let expected = row - runStart < 4 ? runStart : nil
        #expect(controller.artRow(row) == expected, "row \(row)")
        if expected != nil, expected != row { spanned = true }
        let cell = controller.table.view(atColumn: art, row: row, makeIfNecessary: true)
        #expect(cell is AlbumArtCell, "row \(row)")
        if let expected { #expect((cell as? AlbumArtCell)?.rowsDown == row - expected) }
    }
    #expect(spanned)
}
