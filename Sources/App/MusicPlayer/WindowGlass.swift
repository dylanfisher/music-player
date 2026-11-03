import AppKit
import LibraryBrowser

/// The main window's glass, `appearance.glass` (ADR 0072): the sidebar's translucent material
/// under the whole window, the toolbar transparent over it, the lists drawing no background of
/// their own, and the bars' materials blending with what's behind the window instead of what's
/// in it. Off, the window is as AppKit draws it.
@MainActor
final class WindowGlass {
    private let window: NSWindow
    private let backdrop = NSVisualEffectView()
    /// What each list and material had before the glass, to put back.
    private var tables: [(NSTableView, NSColor, Bool)] = []
    private var scrolls: [NSScrollView] = []
    private var materials: [NSVisualEffectView] = []
    private var headerCells: [(NSTableColumn, NSTableHeaderCell)] = []
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
        if on {
            window.styleMask.insert(.fullSizeContentView)
            clear(in: window.contentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
            restore()
        }
    }

    /// Makes every list under `view` transparent, and every material that blends with the
    /// window's content blend with what's behind the window, remembering what each had.
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
            if table.headerView != nil {
                for column in table.tableColumns {
                    headerCells.append((column, column.headerCell))
                    column.headerCell = ClearHeaderCell(copying: column.headerCell)
                }
                table.headerView?.needsDisplay = true
            }
            if let scroll = table.enclosingScrollView, scroll.drawsBackground {
                scrolls.append(scroll)
                scroll.drawsBackground = false
            }
        }
        if let material = view as? NSVisualEffectView, material.blendingMode == .withinWindow {
            materials.append(material)
            material.blendingMode = .behindWindow
        }
        for subview in view.subviews { clear(in: subview) }
    }

    private func restore() {
        for (table, color, alternating) in tables {
            table.backgroundColor = color
            table.usesAlternatingRowBackgroundColors = alternating
        }
        for (column, cell) in headerCells {
            column.headerCell = cell
            column.tableView?.headerView?.needsDisplay = true
        }
        for scroll in scrolls { scroll.drawsBackground = true }
        for material in materials { material.blendingMode = .withinWindow }
        tables = []
        scrolls = []
        materials = []
        headerCells = []
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
