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
    // A row view with an identifier is one the table reuses, rather than one it keeps for
    // every row scrolled past.
    #expect(controller.tableView(controller.table, rowViewForRow: 0)?.identifier != nil)

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

@MainActor @Test func anEmptyHistorySaysNothingPlayedYet() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true,
        groupByAlbumArtist: false)
    let actions = BrowserActions(
        play: { _, _ in }, playNext: { _ in }, move: { _, _ in },
        sort: { _, _ in },
        layoutChanged: { _ in },
        failed: { Issue.record("\($0)") }, keyCommand: { _ in .unbound })
    let controller = TrackTableController(
        model: model, cache: RowCache { _ in [] }, layout: AppState().trackTable.defaultValue,
        actions: actions)
    _ = controller.view
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: .history, genre: nil, artist: nil, album: nil))
    #expect(controller.table.numberOfRows == 0)
    #expect(!controller.emptyLabel.isHidden)
    #expect(controller.emptyLabel.stringValue == "Nothing played yet")
    await model.setSource(nil)
    #expect(controller.table.numberOfRows > 0)
    #expect(controller.emptyLabel.isHidden)
}

/// Scrolling costs per row what reusing and drawing its cells costs, so no cell has a
/// constraint to solve or a text field with a layer of its own, and the table is layer-backed,
/// which responsive scrolling needs.
@MainActor @Test func cellsDrawTheirTextWithoutConstraintsOrALayerPerField() async throws {
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
    var layout = AppState().trackTable.defaultValue
    layout.columns.insert(ColumnLayout(column: .art, width: TrackColumn.art.defaultWidth), at: 0)
    let controller = TrackTableController(
        model: model, cache: RowCache { try index.rows(ids: $0) }, layout: layout,
        actions: actions)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    defer { window.close() }
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    window.displayIfNeeded()

    let table = controller.table
    #expect(table.enclosingScrollView?.wantsLayer == true)
    #expect(KeyTableView.isCompatibleWithResponsiveScrolling)
    #expect(!table.usesAutomaticRowHeights)
    #expect(table.rowView(atRow: 0, makeIfNecessary: false)?.canDrawSubviewsIntoLayer == true)
    let first = try #require(try index.rows(ids: [model.trackIDs[0]]).first)
    for (number, tableColumn) in table.tableColumns.enumerated() where !tableColumn.isHidden {
        let column = try #require(TrackColumn(rawValue: tableColumn.identifier.rawValue))
        let cell = try #require(table.view(atColumn: number, row: 0, makeIfNecessary: false))
        #expect(([cell] + cell.subviews).allSatisfy { $0.constraints.isEmpty }, "\(column)")
        if column == .art {
            #expect(
                (cell as? NSTableCellView)?.imageView?.frame == cell.bounds.insetBy(dx: 1, dy: 1))
        } else {
            let text = try #require(cell as? TextCell, "\(column)")
            #expect(text.subviews.isEmpty)
            #expect(text.text == column.text(first, position: 0))
        }
    }
    // The text stays centered in a taller row, and draws.
    let cell = TextCell(NSUserInterfaceItemIdentifier("t"), numeric: true)
    cell.frame = NSRect(x: 0, y: 0, width: 120, height: 40)
    #expect(abs(cell.textRect.midY - 20) <= 1)
    #expect(cell.textRect.width == 116)
    cell.text = "12:34"
    let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
    cell.cacheDisplay(in: cell.bounds, to: bitmap)
    let drawn = (0..<bitmap.pixelsWide).contains { x in
        (0..<bitmap.pixelsHigh).contains { y in
            (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
        }
    }
    #expect(drawn)
}
