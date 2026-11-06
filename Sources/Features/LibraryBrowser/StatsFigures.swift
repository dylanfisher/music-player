import AppKit

/// Large figures, each its value over its name, sharing the width evenly: the totals of
/// Listening Stats. They sit in one row at the top, or in two rows sharing the height when two
/// fit, as when the totals are as tall as Plays per Day beside them.
final class StatsFigures: NSView {
    struct Figure: Equatable {
        var value: String
        var name: String
        /// What the figure means, in its tooltip.
        var help: String?
    }

    static let spacingPoints: CGFloat = 8
    /// One view per figure, its value over its name, in order.
    private(set) var columns: [NSStackView] = []
    /// The value labels, in order, for tests and VoiceOver.
    private(set) var valueLabels: [NSTextField] = []
    var valueFontSize: CGFloat = 22

    var figures: [Figure] = [] {
        didSet { if figures != oldValue { rebuild() } }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard !columns.isEmpty else { return }
        let spacing = Self.spacingPoints
        let figureHeight = columns.map(\.fittingSize.height).max() ?? 0
        let rows = columns.count > 1 && bounds.height >= 2 * figureHeight + spacing ? 2 : 1
        let perRow = (columns.count + rows - 1) / rows
        let width = (bounds.width - CGFloat(perRow - 1) * spacing) / CGFloat(perRow)
        let rowHeight = bounds.height / CGFloat(rows)
        for (place, column) in columns.enumerated() {
            let row = place / perRow
            // One row at the top; two each in the middle of their half.
            let top =
                rows == 1 ? 0 : CGFloat(row) * rowHeight + (rowHeight - figureHeight) / 2
            column.frame = NSRect(
                x: CGFloat(place % perRow) * (width + spacing), y: top, width: max(0, width),
                height: figureHeight)
        }
    }

    private func rebuild() {
        for view in columns { view.removeFromSuperview() }
        columns = []
        valueLabels = []
        for figure in figures {
            let value = NSTextField(labelWithString: figure.value)
            value.font = .monospacedDigitSystemFont(ofSize: valueFontSize, weight: .semibold)
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let name = NSTextField(labelWithString: figure.name)
            name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            name.textColor = .secondaryLabelColor
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let column = NSStackView(views: [value, name])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 0
            column.toolTip = figure.help
            column.setAccessibilityElement(true)
            column.setAccessibilityRole(.staticText)
            column.setAccessibilityLabel("\(figure.name): \(figure.value)")
            addSubview(column)
            columns.append(column)
            valueLabels.append(value)
        }
        needsLayout = true
    }
}
