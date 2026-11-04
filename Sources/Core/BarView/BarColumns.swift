import AppKit
import Settings

/// A `BarLayout`'s columns as views in a `CenteredRow`: the center column is the row's middle,
/// and the side columns go in the stacks at the row's edges. Each layout makes the side columns
/// afresh, and flexible columns share the free width equally (ADR 0085). The status bar and the
/// toolbar's status each have their own.
@MainActor
public final class BarColumns {
    /// A column's parts' views in order, and the one of them that takes the width the others
    /// leave.
    public typealias Content = (views: [NSView], stretching: NSView?)

    /// The center column, which the row holds as its middle.
    public let center = StatusColumn()
    /// The columns that put their parts one over another, whose height the bar fits.
    public private(set) var stacked: [StatusColumn] = []
    private var sides: [StatusColumn] = []
    private var leadingCount = 0
    private var equalWidths: [NSLayoutConstraint] = []

    public init() {}

    /// Lays out `layout` in `row`, whose middle is `center`: the leading columns after what
    /// `leading` holds, the trailing ones in `trailing` before `trailingBefore`, or last.
    /// `content` gives each column's views, and `stacks` whether it stacks them.
    public func layOut<Part>(
        _ layout: BarLayout<Part>, in row: CenteredRow, leading: NSStackView,
        trailing: NSStackView, trailingBefore: NSView?, spacing: CGFloat,
        stacks: (BarPlace) -> Bool, content: (BarPlace, BarColumn<Part>) -> Content
    ) {
        for column in sides {
            for view in column.stack.arrangedSubviews { view.removeFromSuperview() }
            column.removeFromSuperview()
        }
        sides = []
        leadingCount = layout.leading.count
        NSLayoutConstraint.deactivate(equalWidths)
        var flexible: [StatusColumn] = []
        stacked = []
        for (place, column) in layout.columns {
            let view = place == .center ? center : StatusColumn()
            let (views, stretching) = content(place, column)
            for part in views { prepare(part, stretches: part === stretching) }
            let stacks = stacks(place)
            view.show(
                views, stretching: stretching, alignment: column.alignment, stacks: stacks,
                width: column.width, spacing: spacing)
            if stacks { stacked.append(view) }
            if column.width == .flexible { flexible.append(view) }
            switch place {
            case .leading:
                sides.append(view)
                leading.addArrangedSubview(view)
            case .trailing:
                sides.append(view)
                let index =
                    trailingBefore.flatMap { trailing.arrangedSubviews.firstIndex(of: $0) }
                    ?? trailing.arrangedSubviews.count
                trailing.insertArrangedSubview(view, at: index)
            case .center: break
            }
        }
        equalWidths = flexible.dropFirst().map { column in
            let equal = column.widthAnchor.constraint(equalTo: flexible[0].widthAnchor)
            equal.priority = StatusColumn.equalPriority
            return equal
        }
        NSLayoutConstraint.activate(equalWidths)
        row.middleFills = layout.center.width == .flexible
        row.leadingFills = layout.leading.contains { $0.width == .flexible }
        row.trailingFills = layout.trailing.contains { $0.width == .flexible }
    }

    /// The column at `place`, or nil for a side column the layout doesn't have.
    public func column(at place: BarPlace) -> StatusColumn? {
        switch place {
        case .center: center
        case .leading(let index): index < leadingCount ? sides[index] : nil
        case .trailing(let index): sides.dropFirst(leadingCount + index).first
        }
    }

    /// Sets a part's view to stretch across its column or to keep its width.
    private func prepare(_ view: NSView, stretches: Bool) {
        view.setContentHuggingPriority(stretches ? .init(1) : .defaultHigh, for: .horizontal)
        // Text the row can truncate before anything moves a divider (ADR 0084).
        yieldText(in: view)
        // A part's own stack hugs just under its labels, as a column's does.
        (view as? NSStackView)?.setHuggingPriority(
            stretches ? .init(1) : .init(CenteredRow.textCompressionPriority.rawValue - 1),
            for: .horizontal)
    }

    /// Lets every label under `view` that truncates give way to the row's layout.
    private func yieldText(in view: NSView) {
        if let label = view as? NSTextField, label.lineBreakMode == .byTruncatingTail {
            label.setContentCompressionResistancePriority(
                CenteredRow.textCompressionPriority, for: .horizontal)
        }
        for subview in view.subviews { yieldText(in: subview) }
    }
}
