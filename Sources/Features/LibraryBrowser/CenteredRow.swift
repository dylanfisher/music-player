import AppKit

/// Three views in a row: `leading` and `trailing` at the row's edges, and `middle` centered on
/// its window's content view, so it lines up with the window's title wherever the row sits and
/// whatever the edges hold (ADR 0084). Every constraint that places or sizes the middle is below
/// the priority at which a split view's pane keeps its width, and so below the window's: no
/// content can move a divider or resize the window. When the middle can't be centered without
/// overlapping an edge view it moves aside instead, and only when nothing fits at all does it
/// overlap them.
final class CenteredRow: NSView {
    /// Keeps the middle clear of the edge views, under `NSSplitViewItem`'s lowest holding
    /// priority, 250, so content wider than the row overlaps rather than widens its pane.
    static let clearancePriority = NSLayoutConstraint.Priority(240)
    /// Under the clearance, so the middle moves aside before it overlaps.
    static let centeringPriority = NSLayoutConstraint.Priority(230)
    /// Centered in the row itself, before the row is in a window.
    static let rowCenteringPriority = NSLayoutConstraint.Priority(220)
    /// How hard text in the row resists truncation: under the centering, so text gives way
    /// before the middle moves aside.
    static let textCompressionPriority = NSLayoutConstraint.Priority(210)
    /// The middle's pull to the row's width, under the centering, so it grows evenly to both
    /// sides until the nearer edge view stops it.
    static let fillPriority = NSLayoutConstraint.Priority(200)

    let leading: NSView
    let middle: NSView
    let trailing: NSView
    private lazy var fill: NSLayoutConstraint = {
        let fill = middle.widthAnchor.constraint(equalTo: widthAnchor)
        fill.priority = Self.fillPriority
        return fill
    }()
    private var windowCentering: NSLayoutConstraint?

    /// Whether the middle takes all the width it can while staying centered, rather than its
    /// fitting width.
    var middleFills: Bool {
        get { fill.isActive }
        set { fill.isActive = newValue }
    }

    init(leading: NSView, middle: NSView, trailing: NSView, spacing: CGFloat, inset: CGFloat) {
        self.leading = leading
        self.middle = middle
        self.trailing = trailing
        super.init(frame: .zero)
        for view in [leading, middle, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        let rowCentering = middle.centerXAnchor.constraint(equalTo: centerXAnchor)
        rowCentering.priority = Self.rowCenteringPriority
        let clearance = [
            middle.leadingAnchor.constraint(
                greaterThanOrEqualTo: leading.trailingAnchor, constant: spacing),
            middle.trailingAnchor.constraint(
                lessThanOrEqualTo: trailing.leadingAnchor, constant: -spacing),
        ]
        for constraint in clearance { constraint.priority = Self.clearancePriority }
        NSLayoutConstraint.activate(
            [
                leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                rowCentering,
            ] + clearance)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowCentering?.isActive = false
        windowCentering = nil
        guard let content = window?.contentView, isDescendant(of: content) else { return }
        let centering = middle.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        centering.priority = Self.centeringPriority
        centering.isActive = true
        windowCentering = centering
    }
}
