import AppKit

/// Three views in a row: `leading` and `trailing` at the row's edges, and `middle` centered on
/// its window's content view, so it lines up with the window's title wherever the row sits and
/// whatever the edges hold (ADR 0084). Every constraint that places or sizes the middle is below
/// the window's size priority: no content can resize the window, and when the middle can't be
/// centered without overlapping an edge view it moves aside instead.
final class CenteredRow: NSView {
    /// Under `NSWindow`'s 500, at which the window keeps its size.
    static let centeringPriority = NSLayoutConstraint.Priority(490)
    /// Centered in the row itself, before the row is in a window.
    static let rowCenteringPriority = NSLayoutConstraint.Priority(480)
    /// The middle's pull to the row's width, under the centering, so it grows evenly to both
    /// sides until the nearer edge view stops it.
    static let fillPriority = NSLayoutConstraint.Priority(470)

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
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            middle.leadingAnchor.constraint(
                greaterThanOrEqualTo: leading.trailingAnchor, constant: spacing),
            middle.trailingAnchor.constraint(
                lessThanOrEqualTo: trailing.leadingAnchor, constant: -spacing),
            rowCentering,
        ])
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
