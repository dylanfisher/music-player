import AppKit
import Settings

/// A list cell of one line of text, in the lists' small font unless `font` says otherwise, cut
/// off at its end, aligned as its column says. It draws the text itself: a text field per cell has a layer of its own and a layout
/// pass each time the table reuses the cell, which were most of what scrolling cost per row
/// (ADR 0058).
final class TextCell: NSTableCellView {
    static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// The space between the text and the column's edges.
    static let inset: CGFloat = 2
    /// How much wider than a plain space the space after `mark` is, in points, so the mark
    /// stands apart from the text.
    static let markGap: CGFloat = 4

    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    /// Drawn before `text`, with a space `markGap` wider than a plain one between them, such as
    /// the playing triangle before a title; empty for none.
    var mark = "" {
        didSet { if mark != oldValue { needsDisplay = true } }
    }
    var textColor = NSColor.labelColor {
        didSet { if textColor != oldValue { needsDisplay = true } }
    }
    var font = TextCell.font {
        didSet {
            guard font != oldValue else { return }
            attributes[.font] = font
            needsDisplay = true
        }
    }
    private var attributes: [NSAttributedString.Key: Any]

    init(_ identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        attributes = [.font: Self.font, .paragraphStyle: paragraph]
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: RowListController.rowHeight))
        self.identifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// A selected row's text takes the selection's text color while the list has the keys, and
    /// so does a playing row dark enough for it (`MarkedRowView`).
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    /// Where the text draws: inset from the column's edges, one line tall, centered across the
    /// row's height.
    var textRect: NSRect {
        let height = ceil(font.ascender - font.descender + font.leading)
        return NSRect(
            x: Self.inset, y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - 2 * Self.inset), height: height)
    }

    /// The color the text draws in, which the row's style decides over `textColor`.
    var drawnColor: NSColor {
        backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : textColor
    }

    /// The mark, its wide space and the text, as they draw.
    var markedLine: NSAttributedString {
        var attributes = attributes
        attributes[.foregroundColor] = drawnColor
        var space = attributes
        space[.kern] = Self.markGap
        let line = NSMutableAttributedString(string: mark, attributes: attributes)
        line.append(NSAttributedString(string: " ", attributes: space))
        line.append(NSAttributedString(string: text, attributes: attributes))
        return line
    }

    override func draw(_ dirtyRect: NSRect) {
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        guard mark.isEmpty else { return markedLine.draw(with: textRect, options: options) }
        guard !text.isEmpty else { return }
        var attributes = attributes
        attributes[.foregroundColor] = drawnColor
        (text as NSString).draw(with: textRect, options: options, attributes: attributes)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { mark.isEmpty ? text : mark + " " + text }
}

extension TrackColumn {
    /// How a column's text cells align: numbers on the right, Now Playing's lone triangle in
    /// the middle, the rest on the left.
    var alignment: NSTextAlignment {
        if isNumeric { return .right }
        return self == .nowPlaying ? .center : .left
    }
}
