import AppKit

/// A ranked list of Listening Stats, drawn rather than built from views: each row its rank,
/// name, detail and value over a bar as long as its share of the first row's. A row that can be
/// shown is highlighted under the pointer and reports a click; a dimmed one (plays no longer in
/// the library) can't. Flipped and as tall as its rows, for a scroll view.
final class StatsListView: NSView {
    struct Row: Equatable {
        var rank: Int?
        var name: String
        var detail: String?
        var value: String
        /// The bar's length, from 0 to 1.
        var fraction: Double
        var dimmed = false
    }

    static let rowHeightPoints: CGFloat = 20

    var rows: [Row] = [] {
        didSet {
            guard rows != oldValue else { return }
            hovered = nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityChildren(rows.indices.map(accessibilityRow))
        }
    }
    /// The bars' color; the list's title color by default.
    var barColor = NSColor.controlAccentColor
    var clicked: (Int) -> Void = { _ in }
    /// The text shown when there are no rows.
    var emptyText = noPlaysText
    private(set) var hovered: Int? {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(Self.rowHeightPoints, CGFloat(rows.count) * Self.rowHeightPoints))
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackMouseMoves()
    }

    /// The row at `point`, in the view's coordinates; nil between rows' ends.
    func row(at point: NSPoint) -> Int? {
        let row = Int(point.y / Self.rowHeightPoints)
        return point.y >= 0 && rows.indices.contains(row) ? row : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        hovered = row.flatMap { rows[$0].dimmed ? nil : $0 }
        toolTip = row.map { rows[$0].fullText }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let row = row(at: convert(event.locationInWindow, from: nil)), !rows[row].dimmed
        else { return }
        clicked(row)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else {
            emptyText.draw(
                at: NSPoint(x: 0, y: 2),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
            return
        }
        let height = Self.rowHeightPoints
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let digits = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let rankWidth: CGFloat = rows.count >= 10 ? 22 : 16
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        for (place, row) in rows.enumerated() {
            let frame = NSRect(
                x: 0, y: CGFloat(place) * height, width: bounds.width, height: height)
            guard frame.intersects(dirtyRect) else { continue }
            if place == hovered {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
            }
            let barStart = rankWidth
            let barFrame = NSRect(
                x: barStart, y: frame.maxY - 4,
                width: max(2, (bounds.width - barStart) * CGFloat(min(1, max(0, row.fraction)))),
                height: 2.5)
            (row.dimmed ? NSColor.tertiaryLabelColor : barColor).withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: barFrame, xRadius: 1.25, yRadius: 1.25).fill()

            let primary: NSColor = row.dimmed ? .tertiaryLabelColor : .labelColor
            let secondary: NSColor = row.dimmed ? .tertiaryLabelColor : .secondaryLabelColor
            if let rank = row.rank {
                let text = NSAttributedString(
                    string: "\(rank)",
                    attributes: [.font: digits, .foregroundColor: NSColor.tertiaryLabelColor])
                text.draw(at: NSPoint(x: 0, y: frame.minY + 2))
            }
            let value = NSAttributedString(
                string: row.value, attributes: [.font: digits, .foregroundColor: secondary])
            let valueWidth = ceil(value.size().width)
            value.draw(at: NSPoint(x: bounds.width - valueWidth - 2, y: frame.minY + 2))
            let title = NSMutableAttributedString(
                string: row.name,
                attributes: [.font: font, .foregroundColor: primary, .paragraphStyle: truncating])
            if let detail = row.detail, !detail.isEmpty {
                title.append(
                    NSAttributedString(
                        string: "  " + detail,
                        attributes: [
                            .font: small, .foregroundColor: secondary, .paragraphStyle: truncating,
                        ]))
            }
            title.draw(
                with: NSRect(
                    x: barStart, y: frame.minY + 1,
                    width: max(0, bounds.width - barStart - valueWidth - 10), height: height - 4),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func accessibilityRow(_ place: Int) -> NSAccessibilityElement {
        let row = rows[place]
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.staticText)
        element.setAccessibilityLabel(row.fullText)
        element.setAccessibilityParent(self)
        element.setAccessibilityFrameInParentSpace(
            NSRect(
                x: 0, y: bounds.height - CGFloat(place + 1) * Self.rowHeightPoints,
                width: bounds.width, height: Self.rowHeightPoints))
        return element
    }
}

extension StatsListView.Row {
    /// The row as one line, for its tooltip and VoiceOver.
    var fullText: String {
        [rank.map { "\($0)." }, name, detail.map { "– \($0)" }, value].compactMap { $0 }
            .joined(separator: " ")
    }
}

/// What a list or the clock says when the period has no plays.
let noPlaysText = "No plays"
