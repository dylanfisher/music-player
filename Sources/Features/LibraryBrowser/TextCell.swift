import AppKit

/// A list cell of one line of text in the lists' small font, cut off at its end, numbers on the
/// right. It draws the text itself: a text field per cell has a layer of its own and a layout
/// pass each time the table reuses the cell, which were most of what scrolling cost per row
/// (ADR 0056).
final class TextCell: NSTableCellView {
    static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// The space between the text and the column's edges.
    static let inset: CGFloat = 2

    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var textColor = NSColor.labelColor {
        didSet { if textColor != oldValue { needsDisplay = true } }
    }
    private let attributes: [NSAttributedString.Key: Any]

    init(_ identifier: NSUserInterfaceItemIdentifier, numeric: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = numeric ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        attributes = [.font: Self.font, .paragraphStyle: paragraph]
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: RowListController.rowHeight))
        self.identifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// A selected row's text takes the selection's text color while the list has the keys.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    /// Where the text draws: inset from the column's edges, one line tall, centered across the
    /// row's height.
    var textRect: NSRect {
        let height = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        return NSRect(
            x: Self.inset, y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - 2 * Self.inset), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        var attributes = attributes
        attributes[.foregroundColor] =
            backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : textColor
        (text as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}
