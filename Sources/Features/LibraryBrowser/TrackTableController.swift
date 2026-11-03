import AppKit
import Artwork
import Commands
import DisplayText
import Library
import Log
import Settings

private let logger = moduleLogger()

/// The track table. It asks the model for IDs and the row cache for rows, and reports what the
/// user does; it decides nothing itself.
@MainActor
final class TrackTableController: RowListController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    private let model: BrowserModel
    private let cache: RowCache
    private let actions: BrowserActions
    /// Set while the table's sort descriptors are being set from the model, so that doesn't
    /// count as the user sorting.
    private var applyingSort = false
    /// Set while `showColumns` moves and resizes columns.
    private var applyingColumns = false
    /// A row fetch failed; reported once until the next reload.
    private var reportedFetchFailure = false
    private var typeSelect: TypeSelect? = TypeSelect()
    /// How the Album Art column draws, and the loader for the column's width, replaced when the
    /// width needs other pixels.
    private var artSize = ArtSize.fit
    /// The text cells' font, which follows the row height.
    private var font = RowHeight.regular.font
    private var art: RowArt
    /// How the Album Art column reads art from a file, which the scroll measurement replaces.
    var readArt: ArtRead = readArtBytes {
        didSet {
            art = RowArt(pixels: art.loader.maxPixelSize, read: readArt, thumbnails: thumbnails)
            follow(art)
        }
    }
    /// Where the art column's thumbnails are kept between launches; nil keeps none.
    private let thumbnails: ThumbnailStore?
    /// The art of the album under the pointer, whole and at the column's width, over the rows.
    let artHover = ArtHover()
    /// The art opened by a click on `artHover`, while it's open.
    private(set) var artViewer: ArtViewer?
    /// The model's `emptyText`, centered over the table, hidden while it's nil.
    let emptyLabel = NSTextField(labelWithString: "")
    /// Called after every change of the selection, the keys' and a reload's too.
    var selectionChanged: () -> Void = {}
    /// A click in the Rating column: the clicked track and the stars to give it, 0 to clear.
    var rateClicked: (Int64, Int) -> Void = { _, _ in }
    /// Runs a click's rating once a double-click can no longer follow it.
    var afterDoubleClickInterval: (@escaping @MainActor () -> Void) -> Void = { rate in
        Task { @MainActor in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(NSEvent.doubleClickInterval * 1_000_000_000))
            } catch {
                return
            }
            rate()
        }
    }
    /// Counts clicks in the Rating column, so a double-click drops its first click's rating.
    private var ratingClicks = 0
    /// The ratings clicks set since the rows were last read, which the row cache doesn't hold
    /// yet, so a second click on the same star clears it.
    private var ratingsSet: [Int64: Int] = [:]
    /// The file of the track playing, whose row is marked wherever the table shows it.
    var playingPath: String? {
        didSet {
            guard playingPath != oldValue else { return }
            table.enumerateAvailableRowViews { rowView, row in
                (rowView as? MarkedRowView)?.isMarked = isPlaying(row)
            }
        }
    }

    init(
        model: BrowserModel, cache: RowCache, layout: TrackTableLayout, actions: BrowserActions,
        thumbnails: ThumbnailStore?
    ) {
        self.model = model
        self.cache = cache
        self.actions = actions
        self.thumbnails = thumbnails
        art = RowArt(
            pixels: RowArt.pixels(
                columnWidth: layout.columns.first { $0.column == .art }?.width
                    ?? TrackColumn.art.defaultWidth), read: readArtBytes, thumbnails: thumbnails)
        super.init(play: actions.play, playNext: actions.playNext)
        configure(layout)
        follow(art)
        artHover.clicked = { [weak self] in self?.openHoveredArt() }
    }

    /// Points `art` at the rows on screen. A replaced loader wants nothing more and shows
    /// nothing it was still loading.
    private func follow(_ art: RowArt) {
        art.wanted = { [weak self, weak art] in
            guard let self, art === self.art else { return [] }
            return Set(visibleRows().compactMap(artKey))
        }
        art.loaded = { [weak self, weak art] key, image in
            guard let self, art === self.art else { return }
            show(image, for: key)
        }
    }

    override func loadView() {
        super.loadView()
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        // Centered by frame and mask: a constraint here gives every cell constraints to solve
        // again (ADR 0058).
        emptyLabel.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        view.addSubview(emptyLabel)
        // Laid out by frame, over the rows, so it scrolls with them (ADR 0058).
        artHover.isHidden = true
        table.addSubview(artHover)
        table.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                    .inVisibleRect,
                ], owner: self))
        // The overlay belongs to the rows that were under the pointer, so a scroll by the wheel
        // or a key, which moves other rows under it without a mouse move, hides it.
        let clip = (view as? NSScrollView)?.contentView
        clip?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification,
            object: clip)
    }

    @objc private func clipScrolled(_ notification: Notification) { hideArtHover() }

    private func configure(_ layout: TrackTableLayout) {
        configureRows()
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.dataSource = self
        table.delegate = self
        table.takeKey = { [weak self] event in self?.takeKey(event) ?? false }
        table.action = #selector(clicked)
        table.edgeToEdgeColumn = columnIdentifier(.art)
        table.registerForDraggedTypes([trackIDsType])
        // Rows go only to the sidebar and to other rows, never to another app.
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        let shown = layout.columns.map(\.column)
        let order = shown + TrackColumn.allCases.filter { !shown.contains($0) }
        for column in order {
            let tableColumn = NSTableColumn(identifier: columnIdentifier(column))
            tableColumn.title = column.title
            tableColumn.width =
                layout.columns.first { $0.column == column }?.width
                ?? column.defaultWidth
            tableColumn.minWidth = TrackTableLayout.widthRange.lowerBound
            tableColumn.maxWidth = TrackTableLayout.widthRange.upperBound
            tableColumn.isHidden = !shown.contains(column)
            tableColumn.resizingMask =
                column == .title ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if column.isSortable {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                    key: column.rawValue, ascending: true)
            }
            if column.isNumeric { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        let header = NSMenu()
        header.delegate = self
        table.headerView?.menu = header
        showSort()
    }

    /// Draws the lines, rows and art as the appearance settings say.
    func apply(_ appearance: TableAppearance) {
        self.appearance = appearance
        var lines: NSTableView.GridLineStyle = []
        if appearance.columnLines { lines.insert(.solidVerticalGridLineMask) }
        if appearance.rowLines { lines.insert(.solidHorizontalGridLineMask) }
        table.gridStyleMask = lines
        table.usesAlternatingRowBackgroundColors = appearance.alternatingRows && !appearance.glass
        let rowHeight = appearance.rowHeight.points
        guard appearance.artSize != artSize || rowHeight != table.rowHeight else { return }
        table.rowHeight = rowHeight
        font = appearance.rowHeight.font
        artSize = appearance.artSize
        hideArtHover()
        // The art's rows and size, and the text's size, change.
        table.reloadData()
    }

    // MARK: Model to view

    /// Reloads after the model changed, keeping the selected tracks selected, and the first
    /// visible track in place when the library changed under the user. The table still shows
    /// `change.previousIDs`, so the selection and position are read through those.
    func reload(_ change: BrowserChange) {
        reportedFetchFailure = false
        ratingsSet = [:]
        if change.reason == .libraryChanged, change.previousIDs == model.trackIDs {
            redrawChangedRows()
            return
        }
        let selection = Set(
            table.selectedRowIndexes.compactMap {
                change.previousIDs.indices.contains($0) ? change.previousIDs[$0] : nil
            })
        let anchor =
            change.reason == .libraryChanged ? scrollAnchor(in: change.previousIDs) : nil
        cache.setIDs(model.trackIDs)
        hideArtHover()
        // Its album may no longer be among the rows.
        artViewer?.close()
        showSort()
        typeSelect?.reset()
        table.reloadData()
        emptyLabel.stringValue = model.emptyText ?? ""
        emptyLabel.sizeToFit()
        emptyLabel.setFrameOrigin(
            NSPoint(
                x: (view.bounds.width - emptyLabel.frame.width) / 2,
                y: (view.bounds.height - emptyLabel.frame.height) / 2))
        emptyLabel.isHidden = model.emptyText == nil
        let rows = model.rows(holding: selection)
        select(rows)
        if let anchor {
            restore(anchor, row: model.rows(holding: [anchor.id]).first)
        } else if let first = rows.first {
            center(first)
        } else if !model.trackIDs.isEmpty {
            table.scrollRowToVisible(0)
        }
    }

    /// Reads the rows again after a rescan that kept the same tracks in the same order, and
    /// redraws only those with views whose tags or stats changed. A scan refreshes every 2 s, and
    /// reloading the whole table rebuilds every row on screen each time. The table keeps views
    /// for some rows just off screen too, so those are compared as well.
    private func redrawChangedRows() {
        var prepared: [Int] = []
        table.enumerateAvailableRowViews { _, row in prepared.append(row) }
        let shown = prepared.map(trackRow)
        cache.setIDs(model.trackIDs)
        let now = prepared.map(trackRow)
        let changed = prepared.indices.filter { now[$0] != shown[$0] }
        guard !changed.isEmpty else { return }
        let rows = IndexSet(changed.map { prepared[$0] })
        table.reloadData(
            forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        for row in rows {
            (table.rowView(atRow: row, makeIfNecessary: false) as? MarkedRowView)?.isMarked =
                isPlaying(row)
        }
        // An album's art spans its rows, so a changed cover or album moves where the art of the
        // rows around it starts and ends, and what it shows.
        let art = table.column(withIdentifier: columnIdentifier(.art))
        if art >= 0,
            changed.contains(where: {
                now[$0]?.albumID != shown[$0]?.albumID || now[$0]?.art != shown[$0]?.art
            })
        {
            table.reloadData(forRowIndexes: IndexSet(prepared), columnIndexes: [art])
        }
        // The art shown whole may be another album's now.
        if !rows.intersection(IndexSet(integersIn: hoveredRows)).isEmpty { hideArtHover() }
        if let viewerRows, !rows.intersection(IndexSet(integersIn: viewerRows)).isEmpty {
            artViewer?.close()
        }
    }

    private func showSort() {
        applyingSort = true
        table.sortDescriptors = [
            NSSortDescriptor(key: model.sortColumn.rawValue, ascending: model.ascending)
        ]
        applyingSort = false
    }

    /// Scrolls through every row a screenful at a time, drawing each, and passes each row to
    /// `visit`. Each step moves the clip view as dragging the scroll bar's knob does, which on a
    /// long list jumps about a screenful for each point the knob moves. Returns how long each
    /// step took to scroll and draw, in milliseconds, `visit` left out. For measuring scrolling,
    /// and memory after the whole table has been seen.
    func scrollThroughEveryRow(_ visit: (TrackRow) -> Void) -> [Double] {
        guard let clip, let scrollView = table.enclosingScrollView else { return [] }
        var steps: [Double] = []
        var next = 0
        while next < model.trackIDs.count {
            let start = DispatchTime.now().uptimeNanoseconds
            let bottom = table.bounds.height - clip.bounds.height
            let y = max(
                -clip.contentInsets.top,
                min(table.rect(ofRow: next).minY - clip.contentInsets.top, bottom))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(clip)
            table.window?.displayIfNeeded()
            CATransaction.flush()
            steps.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            let end = max(next + 1, visibleRows().upperBound)
            for index in next..<end {
                if let row = trackRow(index) { visit(row) }
            }
            next = end
        }
        return steps
    }

    /// Puts `row` at the top and draws it.
    func scroll(toRow row: Int) {
        guard let clip, model.trackIDs.indices.contains(row) else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: row).minY))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
        table.window?.displayIfNeeded()
    }

    /// Moves a screenful down the list, as Page Down does, and draws it.
    func pageDown() { scroll(toRow: max(0, visibleRows().upperBound - 1)) }

    /// The appearance last applied, which the resize measurement changes the row height of.
    private var appearance: TableAppearance?

    /// One frame of the resize measurement: the Album Art column a point wider or narrower,
    /// sweeping from its default width to 160 points and back, which crosses the widths that
    /// load art at other pixels, and the window 4 points wider or narrower; every 60th frame
    /// the row height changes instead. True when it did, and draws.
    func resizeFrame(_ frame: Int) -> Bool {
        let column = table.column(withIdentifier: columnIdentifier(.art))
        guard column >= 0, let window = table.window else {
            preconditionFailure("the resize measurement needs the art column in a window")
        }
        if frame % 60 == 59, var appearance {
            appearance.rowHeight = appearance.rowHeight == .compact ? .regular : .compact
            apply(appearance)
        } else {
            let low = TrackColumn.art.defaultWidth
            let sweep = 2 * (160 - low)
            let along = Double(frame % Int(sweep))
            table.tableColumns[column].width = low + (along < sweep / 2 ? along : sweep - along)
            var bounds = window.frame
            bounds.size.width += (frame / 20) % 2 == 0 ? 4 : -4
            window.setFrame(bounds, display: false)
        }
        window.displayIfNeeded()
        CATransaction.flush()
        return frame % 60 == 59
    }

    /// Moves the rows `points` down the list, as one frame of a trackpad scroll does, and draws
    /// them. False once the list's end is on screen.
    func scrollFrame(by points: CGFloat) -> Bool {
        guard let clip, let scrollView = table.enclosingScrollView else { return false }
        let bottom = table.bounds.height - clip.bounds.height
        guard clip.bounds.minY < bottom else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(clip.bounds.minY + points, bottom)))
        scrollView.reflectScrolledClipView(clip)
        table.window?.displayIfNeeded()
        CATransaction.flush()
        return true
    }

    /// How many rows on screen should show art and don't yet: their art is neither drawn nor
    /// known to be unreadable.
    func rowsAwaitingArt() -> Int {
        let column = table.column(withIdentifier: columnIdentifier(.art))
        guard column >= 0 else { return 0 }
        return visibleRows().filter { row in
            guard let key = artKey(row), !art.hasFailed(key) else { return false }
            let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
            return (cell as? AlbumArtCell)?.art == nil
        }.count
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { model.trackIDs.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = MarkedRowView.reused(in: tableView)
        if !rowView.canDrawSubviewsIntoLayer {
            // The row and its cells draw into one layer, not one each.
            rowView.wantsLayer = true
            rowView.canDrawSubviewsIntoLayer = true
        }
        rowView.isMarked = isPlaying(row)
        return rowView
    }

    /// Whether `row` shows the track playing. Read from the row cache, which already holds the
    /// rows on screen.
    func isPlaying(_ row: Int) -> Bool {
        guard let playingPath, model.trackIDs.indices.contains(row) else { return false }
        return trackRow(row)?.path == playingPath
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, let column = TrackColumn(rawValue: tableColumn.identifier.rawValue)
        else { return nil }
        if column == .art {
            rowsDrawn()
            let cell =
                tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
                as? AlbumArtCell ?? makeArtCell(tableColumn.identifier)
            fill(cell, row: row)
            return cell
        }
        let cell =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
            as? TextCell ?? TextCell(tableColumn.identifier, numeric: column.isNumeric)
        cell.font = font
        cell.text = trackRow(row).map { column.text($0, position: row) } ?? ""
        rowsDrawn()
        return cell
    }

    // MARK: Album art

    /// The rows on screen, whose art is worth loading.
    private func visibleRows() -> Range<Int> {
        let rows = table.rows(in: table.visibleRect)
        return rows.location..<min(rows.location + rows.length, model.trackIDs.count)
    }

    /// The row whose art `row` shows, its album's first row; nil for a row below its album's
    /// art.
    func artRow(_ row: Int) -> Int? {
        ArtRun.start(of: row, rowsTall: artRowsTall) { trackRow($0)?.albumID }
    }

    /// The most rows an album's art covers: as many as a square as wide as the column.
    private var artRowsTall: Int {
        let column = table.column(withIdentifier: columnIdentifier(.art))
        guard column >= 0 else { return 1 }
        // The cells fill the column's rect (`edgeToEdgeColumn`), so the art is that wide.
        return max(1, Int((table.rect(ofColumn: column).width / rowPitch).rounded(.up)))
    }

    private var rowPitch: CGFloat { table.rowHeight + table.intercellSpacing.height }

    private func artKey(_ row: Int) -> ArtworkKey? {
        guard let shown = artRow(row), let track = trackRow(shown), let embedded = track.art
        else { return nil }
        return ArtworkKey(path: track.path, art: embedded)
    }

    /// The cached image of `row`'s own art, or nil after asking for it to be loaded.
    private func image(ofArtIn row: Int) -> NSImage? {
        trackRow(row).flatMap { track in
            track.art.flatMap {
                art.image(
                    $0, path: track.path,
                    stamp: FileStamp(
                        sizeBytes: track.sizeBytes, modifiedSeconds: track.modifiedSeconds))
            }.map {
                NSImage(cgImage: $0, size: .zero)
            }
        }
    }

    /// Sets an art cell to its part of its album's art.
    private func fill(_ cell: AlbumArtCell, row: Int) {
        cell.rowPitch = rowPitch
        cell.size = artSize
        guard let start = artRow(row) else {
            cell.art = nil
            return
        }
        cell.rowsDown = row - start
        cell.runRows = ArtRun.length(
            from: start, limit: artRowsTall, rowCount: model.trackIDs.count
        ) { trackRow($0)?.albumID }
        cell.art = image(ofArtIn: start)
    }

    /// Puts a loaded image in each row on screen that shows its art.
    private func show(_ image: CGImage, for key: ArtworkKey) {
        let column = table.column(withIdentifier: columnIdentifier(.art))
        guard column >= 0 else { return }
        for row in visibleRows() where artKey(row) == key {
            let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
            (cell as? AlbumArtCell)?.art = NSImage(cgImage: image, size: .zero)
        }
    }

    /// Fits each art cell to the art column's new width, which moves where an album's art
    /// ends, after loading art at other pixels if the width needs them.
    private func refitArt() {
        let column = table.column(withIdentifier: columnIdentifier(.art))
        guard column >= 0 else { return }
        hideArtHover()
        let pixels = RowArt.pixels(columnWidth: table.tableColumns[column].width)
        if pixels != art.loader.maxPixelSize {
            art = RowArt(pixels: pixels, read: readArt, thumbnails: thumbnails)
            follow(art)
        }
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: column) as? AlbumArtCell).map { fill($0, row: row) }
        }
    }

    // MARK: Hovering and opening art

    override func mouseMoved(with event: NSEvent) {
        showArtHover(at: table.convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hideArtHover() }

    /// Shows the whole art of the album under `point`, in the table's coordinates, over the
    /// rows, and hides it once the pointer leaves the album's rows under it.
    func showArtHover(at point: NSPoint) {
        if !artHover.isHidden, hoverArea.contains(point) { return }
        guard let hovered = hoveredArt(at: point) else {
            hideArtHover()
            return
        }
        hoveredRow = hovered.row
        hoverArea = hovered.area
        artHover.image = hovered.image
        artHover.frame = hovered.frame
        // Row views AppKit adds after the hover's last showing go above it.
        if table.subviews.last !== artHover {
            table.addSubview(artHover, positioned: .above, relativeTo: nil)
        }
        artHover.isHidden = false
    }

    /// The rows `rect` touches, empty for an empty rect.
    private func rowRange(under rect: NSRect) -> Range<Int> {
        guard !rect.isEmpty else { return 0..<0 }
        let rows = table.rows(in: rect)
        return rows.location..<rows.location + rows.length
    }

    func hideArtHover() {
        guard !artHover.isHidden else { return }
        artHover.isHidden = true
        artHover.image = nil
        hoveredRow = nil
        hoverArea = .zero
    }

    /// The album's first row whose art `artHover` shows.
    private var hoveredRow: Int?
    /// The rows under `artHover`'s album, and under the album `artViewer` shows.
    private var hoveredRows: Range<Int> { rowRange(under: hoverArea) }
    private var viewerRows: Range<Int>?
    /// Where the pointer keeps `artHover` showing: its frame over its own album's rows, so the
    /// next album's rows under it hover that album.
    private(set) var hoverArea = NSRect.zero

    /// The art drawn under `point`, with its album's first row, where the whole art goes (as
    /// wide as the column, from the top of that row) and the part of that over the album's
    /// rows. Nil off the art, or before it loaded.
    func hoveredArt(at point: NSPoint) -> (
        row: Int, frame: NSRect, area: NSRect, image: NSImage
    )? {
        let column = table.column(at: point)
        let row = table.row(at: point)
        guard column >= 0, row >= 0,
            table.tableColumns[column].identifier == columnIdentifier(.art),
            let start = artRow(row), let image = image(ofArtIn: start)
        else { return nil }
        // The cells fill the column's rect (`edgeToEdgeColumn`), so the art is that wide.
        let left = table.rect(ofColumn: column).minX
        let width = table.rect(ofColumn: column).width
        let top = table.rect(ofRow: start).minY
        let albumID = { (row: Int) in self.trackRow(row)?.albumID }
        let rows = ArtRun.length(
            from: start, limit: artRowsTall, rowCount: model.trackIDs.count, album: albumID)
        let drawn = ArtFrame.rect(
            artSize, image: image.size, width: width, runHeight: CGFloat(rows) * rowPitch)
        guard drawn.offsetBy(dx: left, dy: top).contains(point) else { return nil }
        let frame = ArtFrame.whole(image: image.size, width: width).offsetBy(dx: left, dy: top)
        let albumRows = ArtRun.length(
            from: start, limit: max(1, Int((frame.height / rowPitch).rounded(.up))),
            rowCount: model.trackIDs.count, album: albumID)
        let area = frame.intersection(
            table.rect(ofRow: start).union(table.rect(ofRow: start + albumRows - 1)))
        return (start, frame, area, image)
    }

    /// Opens the hovered art over the screen, decoded at the screen's size.
    func openHoveredArt() {
        guard let row = hoveredRow, let image = artHover.image, let track = trackRow(row),
            let embedded = track.art, let screen = table.window?.screen ?? NSScreen.main
        else { return }
        viewerRows = hoveredRows
        hideArtHover()
        let viewer = ArtViewer(image: image, screen: screen, owner: table.window)
        viewer.closed = { [weak self, weak viewer] in
            if self?.artViewer === viewer { self?.artViewer = nil }
        }
        artViewer = viewer
        viewer.show()
        viewer.load(embedded, path: track.path, failed: actions.failed)
    }

    // MARK: Rating by click

    @objc private func clicked() {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp,
            event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        else { return }
        rate(at: table.convert(event.locationInWindow, from: nil))
    }

    /// Rates the track at `point`, in the table's coordinates, if it's in the Rating column,
    /// unless a double-click follows, which only plays.
    func rate(at point: NSPoint) {
        let row = table.row(at: point)
        let column = table.column(at: point)
        guard row >= 0, column >= 0,
            table.tableColumns[column].identifier == columnIdentifier(.rating),
            let track = trackRow(row)
        else { return }
        let cell = table.frameOfCell(atColumn: column, row: row)
        let starWidth = (stars(1) as NSString).size(withAttributes: [.font: font]).width
        let x = point.x - cell.minX - TextCell.inset
        ratingClicks += 1
        let click = ratingClicks
        afterDoubleClickInterval { [weak self] in
            guard let self, click == ratingClicks else { return }
            let rating = RatingClick.stars(
                at: x, starWidth: starWidth, current: ratingsSet[track.id] ?? track.rating)
            ratingsSet[track.id] = rating
            rateClicked(track.id, rating)
        }
    }

    override func doubleClicked() { ratingClicks += 1 }

    private func trackRow(_ index: Int) -> TrackRow? {
        do {
            return try cache.row(at: index)
        } catch {
            if !reportedFetchFailure {
                reportedFetchFailure = true
                let message = "couldn't read rows for the table: \(error)"
                logger.error("\(message)")
                actions.failed(message)
            }
            return nil
        }
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        model.trackIDs.indices.contains(row) ? trackDragItem(model.trackIDs[row]) : nil
    }

    /// Rows move only within a manual playlist shown in its own order, between rows.
    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, model.canReorder else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let ids = draggedTrackIDs(info.draggingPasteboard)
        guard !ids.isEmpty, model.canReorder else { return false }
        actions.move(ids, row)
        return true
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard !applyingSort, let first = tableView.sortDescriptors.first, let key = first.key,
            let column = TrackColumn(rawValue: key)
        else { return }
        actions.sort(column, first.ascending)
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        hideArtHover()
        guard !applyingColumns else { return }
        actions.layoutChanged(layout)
        // A drag moves the column a place at a time; the selection is centered once it's off
        // screen, not at every place.
        centerSelectionIfHidden()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        hideArtHover()
        if !applyingColumns { actions.layoutChanged(layout) }
        let resized = notification.userInfo?["NSTableColumn"] as? NSTableColumn
        if resized?.identifier == columnIdentifier(.art) { refitArt() }
    }

    /// Shows `layout`'s columns in its order and widths, and hides the others. The sort is the
    /// model's to change. Each move and resize would report the layout; the caller reports it
    /// once instead.
    func showColumns(_ layout: TrackTableLayout) {
        applyingColumns = true
        defer { applyingColumns = false }
        let shown = Set(layout.columns.map { columnIdentifier($0.column) })
        for tableColumn in table.tableColumns {
            tableColumn.isHidden = !shown.contains(tableColumn.identifier)
        }
        for (place, entry) in layout.columns.enumerated() {
            let identifier = columnIdentifier(entry.column)
            guard let index = table.tableColumns.firstIndex(where: { $0.identifier == identifier })
            else { continue }
            table.tableColumns[index].width = entry.width
            if index != place { table.moveColumn(index, toColumn: place) }
        }
        centerSelection()
    }

    /// The visible columns as they stand, and the model's sort.
    var layout: TrackTableLayout {
        let widths = TrackTableLayout.widthRange
        return TrackTableLayout(
            columns: table.tableColumns.filter { !$0.isHidden }.compactMap { tableColumn in
                TrackColumn(rawValue: tableColumn.identifier.rawValue).map {
                    // Clamped, since Settings refuses a width outside the range.
                    ColumnLayout(
                        column: $0,
                        width: min(
                            max(Double(tableColumn.width.rounded()), widths.lowerBound),
                            widths.upperBound))
                }
            }, sortColumn: model.sortColumn, sortAscending: model.ascending)
    }

    // MARK: Header menu: one item per column, checked when shown

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = table.tableColumns.filter { !$0.isHidden }.count
        for column in TrackColumn.allCases {
            guard let tableColumn = table.tableColumn(withIdentifier: columnIdentifier(column))
            else {
                continue
            }
            let item = NSMenuItem(
                title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = tableColumn.isHidden ? .off : .on
            // The table always keeps one column.
            item.isEnabled = tableColumn.isHidden || visible > 1
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
            let tableColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw))
        else { return }
        tableColumn.isHidden.toggle()
        actions.layoutChanged(layout)
        centerSelection()
    }

    // MARK: Keys

    private func takeKey(_ event: NSEvent) -> Bool {
        routeKey(event, typeSelect: &typeSelect, keyCommand: actions.keyCommand) {
            [weak self] query in
            self?.typeToSelect(query)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if selectionDidChange() { typeSelect?.reset() }
        selectionChanged()
    }

    /// Selects the first row whose sort column starts with `query`, centered, as Go to Item
    /// lands on one.
    private func typeToSelect(_ query: String) {
        let column = model.sortColumn
        Task {
            let names: [TrackName]
            do {
                names = try await model.trackNames()
            } catch {
                actions.failed("couldn't read the tracks' names: \(error)")
                return
            }
            guard query == typeSelect?.query else { return }
            let texts = names.lazy.map { typeSelectText($0, sortedBy: column) }
            guard let row = TypeSelect.firstIndex(startingWith: query, in: texts) else {
                NSSound.beep()
                return
            }
            selectCentered(row)
        }
    }
}

/// The text type-to-select matches in a row of a table sorted by `column`: the artist it sorts
/// by, so a compilation grouped under Various Artists isn't found by a track artist's name, or
/// the album or genre when the table sorts by one, else the title.
func typeSelectText(_ name: TrackName, sortedBy column: TrackColumn) -> String {
    switch column {
    case .artist: name.sortArtist ?? ""
    case .album: name.album ?? ""
    case .genre: name.genre ?? ""
    default: name.title
    }
}

private func columnIdentifier(_ column: TrackColumn) -> NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier(column.rawValue)
}

/// An art cell.
@MainActor
private func makeArtCell(_ identifier: NSUserInterfaceItemIdentifier) -> AlbumArtCell {
    let cell = AlbumArtCell()
    cell.identifier = identifier
    return cell
}
