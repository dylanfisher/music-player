import AppKit
import LibraryBrowser

/// The main window's glass, `appearance.glass` (ADR 0072): the sidebar's translucent material
/// under the whole window, the toolbar transparent over it, and the lists drawing no background
/// of their own. The status bar's material already blends with the rows under it (ADR 0084).
/// Off, the window is as AppKit draws it.
@MainActor
final class WindowGlass {
    private let window: NSWindow
    private let backdrop = NSVisualEffectView()
    /// What each list had before the glass, to put back.
    private var tables: [(NSTableView, NSColor, Bool)] = []
    private var scrolls: [NSScrollView] = []
    private var headerCells: [(NSTableColumn, NSTableHeaderCell)] = []
    private var headerViews: [(NSTableView, NSTableHeaderView)] = []
    private(set) var isOn = false

    /// Makes `content` the window's content, under the toolbar however the window lays out.
    init(window: NSWindow, content: NSView) {
        self.window = window
        let container = NSView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        backdrop.isHidden = true
        for view in [backdrop, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        window.contentView = container
        // The toolbar overlaps the content view once it's full size; the layout guide is the
        // part under it.
        let top =
            (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? container.topAnchor
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: top),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        backdrop.isHidden = !on
        window.titlebarAppearsTransparent = on
        matchStyleMask()
        if on { clear(in: window.contentView) } else { restore() }
    }

    /// Gives the window the full-size content view while the glass is on, and takes it away
    /// while off. In full screen the frame is the screen's, for AppKit to manage and put back, so
    /// the change waits until the window has left full screen and calls this again.
    func matchStyleMask() {
        guard !window.styleMask.contains(.fullScreen),
            window.styleMask.contains(.fullSizeContentView) != isOn
        else { return }
        // A change of the style mask keeps the content's size, so the frame shrinks or grows by
        // the toolbar, and the splits share that out, a fraction of a point to each pane. Both
        // are put back as they were (ADR 0084).
        let frame = window.frame
        let dividers = window.contentView.map(DividerPositions.init) ?? DividerPositions()
        if isOn {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        dividers.restore()
    }

    /// Makes every list under `view` transparent, remembering what each had.
    private func clear(in view: NSView?) {
        guard let view, view !== backdrop else { return }
        // The sidebar's outline already sits on its own material.
        if let table = view as? NSTableView, !(table is NSOutlineView) {
            let color =
                (table as? ResolvedBackgroundTable)?.backgroundAsSet ?? table.backgroundColor
            tables.append((table, color, table.usesAlternatingRowBackgroundColors))
            table.backgroundColor = .clear
            // Alternating rows are opaque, which would hide the glass.
            table.usesAlternatingRowBackgroundColors = false
            if let header = table.headerView {
                let glassHeader = GlassHeaderView(frame: header.frame)
                glassHeader.menu = header.menu
                // Columns shown from the header's menu while the glass is on come with a stock
                // cell, which the header clears before it draws.
                glassHeader.clear = { [weak self] column in self?.clearHeader(of: column) }
                table.tableColumns.forEach(clearHeader)
                headerViews.append((table, header))
                table.headerView = glassHeader
            }
            if let scroll = table.enclosingScrollView, scroll.drawsBackground {
                scrolls.append(scroll)
                scroll.drawsBackground = false
            }
        }
        for subview in view.subviews { clear(in: subview) }
    }

    /// Gives `column` a header cell that draws no background, remembering its own.
    private func clearHeader(of column: NSTableColumn) {
        guard !(column.headerCell is ClearHeaderCell) else { return }
        headerCells.append((column, column.headerCell))
        column.headerCell = ClearHeaderCell(copying: column.headerCell)
    }

    private func restore() {
        for (table, color, alternating) in tables {
            table.backgroundColor = color
            table.usesAlternatingRowBackgroundColors = alternating
        }
        for (column, cell) in headerCells { column.headerCell = cell }
        for (table, header) in headerViews {
            // A menu set while the glass was on is kept.
            header.menu = table.headerView?.menu
            table.headerView = header
        }
        for scroll in scrolls { scroll.drawsBackground = true }
        tables = []
        scrolls = []
        headerCells = []
        headerViews = []
    }
}

/// Where every split view's dividers are under a view, to put back after a change of the window
/// moved them. A divider beside a collapsed pane is left to AppKit.
@MainActor
struct DividerPositions {
    private var positions: [(NSSplitView, Int, CGFloat)] = []

    init() {}

    init(_ view: NSView) {
        if let split = view as? NSSplitView {
            let panes = split.arrangedSubviews
            for (index, pane) in panes.dropLast().enumerated()
            where !split.isSubviewCollapsed(pane) && !split.isSubviewCollapsed(panes[index + 1]) {
                positions.append(
                    (split, index, split.isVertical ? pane.frame.maxX : pane.frame.maxY))
            }
        }
        for subview in view.subviews { positions += DividerPositions(subview).positions }
    }

    func restore() {
        for (split, index, position) in positions {
            split.setPosition(position, ofDividerAt: index)
        }
    }
}

/// A list's header on glass: a translucent tint, a line under it and the column's cells over
/// it. `NSTableHeaderView` fills itself opaque behind any cell that isn't its own, which hid
/// the glass (ADR 0087).
final class GlassHeaderView: NSTableHeaderView {
    static let tint = NSColor.labelColor.withAlphaComponent(0.08)
    /// Clears a column's header cell, for a column added after the glass went on.
    var clear: (NSTableColumn) -> Void = { _ in }

    override func viewWillDraw() {
        tableView?.tableColumns.filter { !($0.headerCell is ClearHeaderCell) }.forEach(clear)
        super.viewWillDraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.tint.setFill()
        dirtyRect.fill(using: .sourceOver)
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1)
            .fill(using: .sourceOver)
        guard let table = tableView else { return }
        // The column being dragged goes last, over the others, where the pointer has it.
        let columns = table.tableColumns.indices
        let order = columns.filter { $0 != draggedColumn } + columns.filter { $0 == draggedColumn }
        for index in order {
            var frame = headerRect(ofColumn: index)
            if index == draggedColumn { frame.origin.x += draggedDistance }
            guard frame.intersects(dirtyRect) else { continue }
            table.tableColumns[index].headerCell.draw(withFrame: frame, in: self)
        }
    }
}

/// A table header cell that draws its title, sort indicator and the line after it, but no
/// background, so the window's glass shows through the header.
final class ClearHeaderCell: NSTableHeaderCell {
    init(copying cell: NSTableHeaderCell) {
        super.init(textCell: cell.stringValue)
        alignment = cell.alignment
        font = cell.font
        lineBreakMode = cell.lineBreakMode
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // The interior draws its title at the top of the frame it's given.
        let textPoints = attributedStringValue.size().height
        var title = cellFrame
        title.origin.y = cellFrame.midY - textPoints / 2
        title.size.height = textPoints
        drawInterior(withFrame: title, in: controlView)
        NSColor.separatorColor.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 3, width: 1, height: cellFrame.height - 6)
            .fill()
    }
}
