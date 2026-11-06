import AppKit

/// One card of Listening Stats: a title, a line beside it that the body can change (what a
/// hovered bar holds), an optional control at the right, and the body below, on a rounded
/// background drawn as the health tiles' are. `columns` is how many of the flow's columns it
/// spans; `heightPoints` its height, or the least it takes when it `fillsRow`.
final class StatsCard: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let body: NSView
    let columns: Int
    let heightPoints: CGFloat
    /// Whether the flow makes it as tall as the tallest card in its row, as the totals are
    /// beside Plays per Day.
    let fillsRow: Bool
    private let background = NSBox()

    static let insetPoints: CGFloat = 12

    init(
        title: String, body: NSView, accessory: NSView? = nil, columns: Int = 1,
        heightPoints: CGFloat = 214, fillsRow: Bool = false
    ) {
        self.body = body
        self.columns = columns
        self.heightPoints = heightPoints
        self.fillsRow = fillsRow
        super.init(frame: .zero)
        background.boxType = .custom
        background.borderWidth = 1
        background.cornerRadius = 8
        background.fillColor = .controlBackgroundColor.withAlphaComponent(0.9)
        background.borderColor = .separatorColor
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let views = [background, titleLabel, detailLabel, body] + (accessory.map { [$0] } ?? [])
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = Self.insetPoints
        var constraints = [
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ]
        if let accessory {
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset + 2),
                accessory.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                detailLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
            ]
        } else {
            constraints.append(
                detailLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -inset))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }
}

/// Cards in rows, as many columns as fit at `minimumColumnPoints` each sharing the width
/// evenly, each card spanning its columns (no more than there are); a card that doesn't fit in
/// a row starts the next, and one that fills its row is as tall as the row's tallest. As tall as
/// its rows, so a scroll view scrolls them.
final class StatsFlowView: NSView {
    static let spacingPoints: CGFloat = 10
    var minimumColumnPoints: CGFloat = 300
    /// At most this many columns, however wide; nil for as many as fit.
    var maximumColumns: Int?
    var insetPoints: CGFloat = 12
    private(set) lazy var height = heightAnchor.constraint(equalToConstant: 0)

    override var isFlipped: Bool { true }

    var cards: [StatsCard] = [] {
        didSet {
            for card in oldValue where !cards.contains(card) { card.removeFromSuperview() }
            for card in cards where card.superview !== self { addSubview(card) }
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let spacing = Self.spacingPoints
        let width = max(0, bounds.width - 2 * insetPoints)
        let fitting = max(1, Int((width + spacing) / (minimumColumnPoints + spacing)))
        let columns = min(fitting, maximumColumns ?? fitting)
        let columnWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        var rows: [[StatsCard]] = []
        var column = columns
        for card in cards {
            let span = min(card.columns, columns)
            if column + span > columns {
                rows.append([])
                column = 0
            }
            rows[rows.count - 1].append(card)
            column += span
        }
        var top: CGFloat = 0
        for row in rows {
            let rowHeight = row.map(\.heightPoints).max() ?? 0
            var x = insetPoints
            for card in row {
                let span = CGFloat(min(card.columns, columns))
                let cardWidth = span * columnWidth + (span - 1) * spacing
                card.frame = NSRect(
                    x: x, y: top, width: cardWidth,
                    height: card.fillsRow ? rowHeight : card.heightPoints)
                x += cardWidth + spacing
            }
            top += rowHeight + spacing
        }
        let fitted = rows.isEmpty ? 0 : top - spacing + insetPoints
        if height.constant != fitted { height.constant = fitted }
    }
}
