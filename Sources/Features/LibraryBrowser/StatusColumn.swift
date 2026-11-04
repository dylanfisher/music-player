import AppKit
import Settings

/// One column of the status bar: its parts in a stack, side by side or one over another, placed
/// in the column by its alignment, or across it when a part stretches. A fixed column holds its
/// width, and a flexible one takes what the row gives it (ADR 0085). Its constraints are all
/// below `CenteredRow.clearancePriority` or tie it to its own stack, so no column can widen a
/// split pane or the window.
final class StatusColumn: NSView {
    /// A fixed width gives way only to keeping clear of the row's edge views, and so keeps its
    /// width when the center column has to move aside.
    static let fixedPriority = NSLayoutConstraint.Priority(235)
    /// Flexible columns share the free width equally, before any text truncates.
    static let equalPriority = NSLayoutConstraint.Priority(215)

    let stack = NSStackView()
    private var placement: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        stack.distribution = .fill
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// Holds `views` in order; `stretching`, one of them, takes the width the others leave.
    func show(
        _ views: [NSView], stretching: NSView?, alignment: BarAlignment, stacks: Bool,
        width: BarWidth, spacing: CGFloat
    ) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view) }
        for view in stack.subviews { view.removeFromSuperview() }
        NSLayoutConstraint.deactivate(placement)
        placement = []
        stack.orientation = stacks ? .vertical : .horizontal
        stack.spacing = stacks ? 0 : spacing
        stack.alignment = stacks ? alignment.stackAlignment : .centerY
        for view in views { stack.addArrangedSubview(view) }
        // A stack's hugging above its labels' compression resistance squeezes them to nothing,
        // so it hugs just under it, or not at all while a part stretches across the column.
        stack.setHuggingPriority(
            stretching == nil ? .init(CenteredRow.textCompressionPriority.rawValue - 1) : .init(1),
            for: .horizontal)
        if let stretching {
            placement += [
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            if stacks {
                let across = stretching.widthAnchor.constraint(equalTo: stack.widthAnchor)
                across.priority = CenteredRow.fillPriority
                placement.append(across)
            }
        } else {
            let place: NSLayoutConstraint =
                switch alignment {
                case .leading: stack.leadingAnchor.constraint(equalTo: leadingAnchor)
                case .center: stack.centerXAnchor.constraint(equalTo: centerXAnchor)
                case .trailing: stack.trailingAnchor.constraint(equalTo: trailingAnchor)
                }
            placement.append(place)
        }
        if case .fixed(let points) = width {
            let fixed = widthAnchor.constraint(equalToConstant: CGFloat(points))
            fixed.priority = Self.fixedPriority
            placement.append(fixed)
        }
        NSLayoutConstraint.activate(placement)
    }
}

extension BarAlignment {
    /// How a label's text lines up in a column of this alignment.
    var textAlignment: NSTextAlignment {
        switch self {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    /// How a stacked column lines its parts up.
    fileprivate var stackAlignment: NSLayoutConstraint.Attribute {
        switch self {
        case .leading: .leading
        case .center: .centerX
        case .trailing: .trailing
        }
    }
}
