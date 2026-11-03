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

@MainActor @Test func aSortOrAColumnChangeCentersTheSelection() async throws {
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
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    #expect(model.trackIDs.count > 100)
    let table = controller.table
    /// How far the selected row's middle is from the visible rows' middle, in rows.
    func offCenter() throws -> CGFloat {
        let clip = try #require(controller.clip)
        let row = try #require(table.selectedRowIndexes.first)
        let visible = clip.bounds.height - clip.contentInsets.top
        let middle = clip.bounds.minY + clip.contentInsets.top + visible / 2
        return abs(table.rect(ofRow: row).midY - middle) / table.rowHeight
    }

    table.selectRowIndexes([60], byExtendingSelection: false)
    table.scrollRowToVisible(0)
    await model.setSort(.title, ascending: false)
    #expect(try offCenter() < 1)

    // A layout with columns to move recenters once, at its end.
    table.scrollRowToVisible(0)
    controller.showColumns(
        TrackTableLayout(
            columns: [
                ColumnLayout(column: .genre, width: 80), ColumnLayout(column: .album, width: 100),
                ColumnLayout(column: .artist, width: 150),
            ], sortColumn: .title, sortAscending: false))
    #expect(try offCenter() < 1)

    // A drag leaves a selection on screen where it is, and brings one off screen back.
    let clip = try #require(controller.clip)
    let row = try #require(table.selectedRowIndexes.first)
    // On screen near the top, not centered.
    clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY - 2 * table.rowHeight))
    #expect(try offCenter() > 2)
    let shown = clip.bounds.origin
    table.moveColumn(0, toColumn: 1)
    #expect(clip.bounds.origin == shown)
    table.scrollRowToVisible(0)
    table.moveColumn(0, toColumn: 1)
    #expect(try offCenter() < 1)
}

@MainActor @Test func typingOrAPaneChangeCentersTheRowItLandsOn() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .title, ascending: true,
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
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    let table = controller.table
    func offCenter() throws -> CGFloat {
        let clip = try #require(controller.clip)
        let row = try #require(table.selectedRowIndexes.first)
        let visible = clip.bounds.height - clip.contentInsets.top
        let middle = clip.bounds.minY + clip.contentInsets.top + visible / 2
        return abs(table.rect(ofRow: row).midY - middle) / table.rowHeight
    }

    // A title well down the list, far enough from its end to center.
    let names = try await model.trackNames()
    let typed = try #require(
        names.indices.dropFirst(names.count / 2).first { row in
            let title = names[row].title.lowercased()
            return title.first?.isLetter == true
                && TypeSelect.firstIndex(
                    startingWith: String(title.prefix(3)), in: names.lazy.map(\.title))
                    == row
                && row < names.count - 20
        })
    table.scrollRowToVisible(0)
    for character in names[typed].title.lowercased().prefix(3) {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0))
        #expect(table.takeKey(event))
    }
    let deadline = Date().addingTimeInterval(10)
    while table.selectedRowIndexes != [typed], Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(table.selectedRowIndexes == [typed])
    #expect(try offCenter() < 1)

    // A change of the panes' grouping lands on the same track, centered.
    table.scrollRowToVisible(0)
    await model.setGroupByAlbumArtist(true)
    #expect(try offCenter() < 1)
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
        rowHeight: settings.rowHeight.defaultValue, artSize: settings.artSize.defaultValue,
        glass: settings.glass.defaultValue)
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
            artSize: .fit, glass: false))
    #expect(
        controller.table.gridStyleMask == [
            .solidVerticalGridLineMask, .solidHorizontalGridLineMask,
        ])
    #expect(!controller.table.usesAlternatingRowBackgroundColors)
    #expect(controller.table.rowHeight == 17)
    controller.apply(
        TableAppearance(
            columnLines: true, rowLines: false, alternatingRows: true, rowHeight: .large,
            artSize: .fit, glass: false))
    #expect(controller.table.gridStyleMask == .solidVerticalGridLineMask)
    #expect(controller.table.rowHeight > RowListController.rowHeight)
    #expect(controller.table.usesAlternatingRowBackgroundColors)
    // The glass leaves out the rows' opaque shading.
    controller.apply(
        TableAppearance(
            columnLines: true, rowLines: false, alternatingRows: true, rowHeight: .large,
            artSize: .fit, glass: true))
    #expect(!controller.table.usesAlternatingRowBackgroundColors)
}

/// A table over the browser library sorted by album, its Album Art column `artWidth` wide,
/// loaded and drawn in a window.
@MainActor
private func artTable(artWidth: CGFloat) async throws -> (
    TrackTableController, BrowserModel, [TrackRow]
) {
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
    let controller = TrackTableController(
        model: model, cache: RowCache { try index.rows(ids: $0) },
        layout: TrackTableLayout(
            columns: [
                ColumnLayout(column: .art, width: artWidth),
                ColumnLayout(column: .title, width: 200),
            ],
            sortColumn: .album, sortAscending: true),
        actions: actions)
    controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 2000)
    model.changed = { controller.reload($0) }
    await model.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    return (controller, model, try index.rows(ids: model.trackIDs))
}

@MainActor @Test func albumArtDrawsEachAlbumOnceFromItsFirstRow() async throws {
    let (controller, _, rows) = try await artTable(artWidth: 3 * RowListController.rowHeight)
    let art = controller.table.column(withIdentifier: NSUserInterfaceItemIdentifier("art"))
    // Square art as wide as the column's rect, its spacing and padding included: 4 rows.
    let tall = Int(
        (controller.table.rect(ofColumn: art).width / RowListController.rowHeight).rounded(.up))
    #expect(tall == 4)
    for size in [ArtSize.fit, .fullWidth] {
        controller.apply(
            TableAppearance(
                columnLines: false, rowLines: false, alternatingRows: true,
                rowHeight: .regular, artSize: size, glass: false))
        var runStart = 0
        var spanned = false
        for row in 0..<min(rows.count, 60) {
            if row > 0, rows[row].albumID == nil || rows[row].albumID != rows[row - 1].albumID {
                runStart = row
            }
            let expected = row - runStart < tall ? runStart : nil
            #expect(controller.artRow(row) == expected, "row \(row)")
            if expected != nil, expected != row { spanned = true }
            let cell = controller.table.view(atColumn: art, row: row, makeIfNecessary: true)
            let artCell = try #require(cell as? AlbumArtCell, "row \(row)")
            #expect(artCell.size == size)
            // Edge to edge across the column, its spacing included.
            #expect(artCell.frame.width == controller.table.rect(ofColumn: art).width)
            if let expected { #expect(artCell.rowsDown == row - expected) }
        }
        #expect(spanned)
    }
}

@MainActor @Test func hoveringArtShowsItWholeAtTheColumnsWidth() async throws {
    let (controller, _, rows) = try await artTable(artWidth: 3 * RowListController.rowHeight)
    let table = controller.table
    let art = table.column(withIdentifier: NSUserInterfaceItemIdentifier("art"))
    let row = try #require(rows.indices.first { rows[$0].art != nil })
    let column = table.rect(ofColumn: art)
    let point = NSPoint(x: column.midX, y: table.rect(ofRow: row).midY)
    // Asks for the art, which loads off the main thread.
    controller.showArtHover(at: point)
    let deadline = Date().addingTimeInterval(10)
    while controller.artHover.isHidden, Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
        controller.showArtHover(at: point)
    }
    try #require(!controller.artHover.isHidden, "the art never loaded")
    let frame = controller.artHover.frame
    #expect(controller.artHover.superview === table)
    #expect(frame.minX >= column.minX && frame.maxX <= column.maxX + 0.5)
    #expect(max(frame.width, frame.height) == column.width)
    #expect(frame.minY == table.rect(ofRow: controller.artRow(row) ?? -1).minY)
    // The pointer stays on it, then leaves the art.
    controller.showArtHover(at: NSPoint(x: frame.midX, y: frame.maxY - 1))
    #expect(!controller.artHover.isHidden)
    let title = table.rect(ofColumn: table.column(withIdentifier: .init("title")))
    controller.showArtHover(at: NSPoint(x: title.midX, y: point.y))
    #expect(controller.artHover.isHidden)
}

@MainActor @Test func scrollingOrMovingAColumnHidesTheArtHover() async throws {
    let (controller, _, rows) = try await artTable(artWidth: 3 * RowListController.rowHeight)
    controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    controller.view.layoutSubtreeIfNeeded()
    let table = controller.table
    let art = table.column(withIdentifier: NSUserInterfaceItemIdentifier("art"))
    let row = try #require(rows.indices.first { rows[$0].art != nil })
    table.scrollRowToVisible(row)
    let point = NSPoint(x: table.rect(ofColumn: art).midX, y: table.rect(ofRow: row).midY)
    func hover() async throws {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            controller.showArtHover(at: point)
            if !controller.artHover.isHidden { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        Issue.record("the art never loaded")
    }
    try await hover()
    controller.scroll(byRows: 1)
    #expect(controller.artHover.isHidden)
    try await hover()
    table.moveColumn(art, toColumn: art + 1)
    #expect(controller.artHover.isHidden)
}

@MainActor @Test func aReloadClosesTheArtViewer() async throws {
    let (controller, model, rows) = try await artTable(artWidth: 3 * RowListController.rowHeight)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    defer { window.close() }
    let table = controller.table
    let art = table.column(withIdentifier: NSUserInterfaceItemIdentifier("art"))
    let row = try #require(rows.indices.first { rows[$0].art != nil })
    table.scrollRowToVisible(row)
    let point = NSPoint(x: table.rect(ofColumn: art).midX, y: table.rect(ofRow: row).midY)
    let deadline = Date().addingTimeInterval(10)
    while controller.artHover.isHidden, Date() < deadline {
        controller.showArtHover(at: point)
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    controller.openHoveredArt()
    let viewer = try #require(controller.artViewer)
    #expect(viewer.window.isVisible)
    await model.setSort(.title, ascending: true)
    #expect(!viewer.window.isVisible)
    #expect(controller.artViewer == nil)
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
            #expect(cell is AlbumArtCell && cell.subviews.isEmpty)
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
