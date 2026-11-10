import AppKit

/// Two tables of the same rows side by side in one scroll view, so they scroll as one in the
/// same frame (ADR 0186). Two scroll views kept together by their bounds notifications lag a
/// frame: AppKit draws a responsive scroll before the main thread hears of it. Each table sits
/// in a clip view of its own that is as tall as the document, so it fits its columns to its
/// half as a table in a scroll view does, and never scrolls on its own; the headers sit in a
/// row above the shared clip view that doesn't scroll. One scroller, at the right table's side.
@MainActor
final class SideBySideTables: NSScrollView {
    /// A table of the pair, whose scroll to a row and drag's autoscroll go to the shared
    /// document, since its own clip view always shows the whole table.
    final class Table: NSTableView {
        override func scrollToVisible(_ rect: NSRect) -> Bool {
            guard let document = (enclosingScrollView as? SideBySideTables)?.documentView else {
                return super.scrollToVisible(rect)
            }
            return document.scrollToVisible(convert(rect, to: document))
        }

        override func autoscroll(with event: NSEvent) -> Bool {
            guard let document = (enclosingScrollView as? SideBySideTables)?.documentView else {
                return super.autoscroll(with: event)
            }
            return document.autoscroll(with: event)
        }

        /// A reload or a change of row count tiles the table, and the shared document takes
        /// its new height.
        override func tile() {
            super.tile()
            (enclosingScrollView as? SideBySideTables)?.layOutDocument()
        }
    }

    let left: Table
    let right: Table
    /// The headers' row, above the clip view.
    private let headers = FlippedView()
    private let clips = [NSClipView(), NSClipView()]
    /// The line between the tables, and between their headers.
    private let dividers = [NSBox(), NSBox()]
    private let headerHeight: CGFloat
    private static let gap: CGFloat = 1
    /// Set while the document is laid out, which tiles the tables, which lay it out again.
    private var layingOut = false

    /// Takes the tables of `left` and `right`, lists in scroll views with their look and
    /// columns, as `inListScrollView` makes them; each must be a `Table`.
    init(_ left: NSScrollView, _ right: NSScrollView) {
        guard let leftTable = left.documentView as? Table,
            let rightTable = right.documentView as? Table
        else { preconditionFailure("each list's document is a SideBySideTables.Table") }
        self.left = leftTable
        self.right = rightTable
        // The header's height is the one its scroll view gives it as it tiles.
        left.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        left.tile()
        headerHeight = leftTable.headerView?.frame.height ?? 0
        left.documentView = nil
        right.documentView = nil
        super.init(frame: .zero)
        borderType = left.borderType
        hasVerticalScroller = true
        let document = FlippedView()
        for (table, clip) in zip([leftTable, rightTable], clips) {
            clip.drawsBackground = false
            clip.documentView = table
            document.addSubview(clip)
            if let header = table.headerView { headers.addSubview(header) }
        }
        for (divider, parent) in zip(dividers, [document, headers]) {
            divider.boxType = .separator
            parent.addSubview(divider)
        }
        documentView = document
        addSubview(headers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// Lays out as a scroll view does, then takes the headers' row from the top of the clip
    /// view and the scroller.
    override func tile() {
        super.tile()
        var clip = contentView.frame
        clip.origin.y += headerHeight
        clip.size.height -= headerHeight
        contentView.frame = clip
        if let scroller = verticalScroller {
            var frame = scroller.frame
            frame.origin.y += headerHeight
            frame.size.height -= headerHeight
            scroller.frame = frame
        }
        headers.frame = NSRect(
            x: clip.minX, y: clip.minY - headerHeight, width: clip.width, height: headerHeight)
        layOutDocument()
    }

    /// The tables' halves of the clip view's width, as tall as the longer table or the clip
    /// view, and their headers over them.
    fileprivate func layOutDocument() {
        guard !layingOut, let document = documentView else { return }
        layingOut = true
        defer { layingOut = false }
        let width = contentView.bounds.width
        let leftWidth = ((width - Self.gap) / 2).rounded(.down)
        let rightX = leftWidth + Self.gap
        let rows = [left, right].map { table in
            table.numberOfRows == 0 ? 0 : table.rect(ofRow: table.numberOfRows - 1).maxY
        }
        let height = max(rows.max() ?? 0, contentView.bounds.height)
        let columns = [(0, leftWidth), (rightX, width - rightX)]
        set(document, NSRect(x: 0, y: 0, width: width, height: height))
        for ((x, columnWidth), (clip, table)) in zip(columns, zip(clips, [left, right])) {
            set(clip, NSRect(x: x, y: 0, width: columnWidth, height: height))
            if let header = table.headerView {
                set(header, NSRect(x: x, y: 0, width: columnWidth, height: headerHeight))
            }
        }
        set(dividers[0], NSRect(x: leftWidth, y: 0, width: Self.gap, height: height))
        set(dividers[1], NSRect(x: leftWidth, y: 0, width: Self.gap, height: headerHeight))
    }

    private func set(_ view: NSView, _ frame: NSRect) {
        if view.frame != frame { view.frame = frame }
    }
}

/// A view laid out from its top, as the document of a scroll view that starts at its first row.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
