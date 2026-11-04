import AppKit

/// Three views in a row: `leading` and `trailing` at the row's edges, and `middle` centered on
/// its window's content view, or on the part of it from `centersFrom` on, so it lines up with
/// the window's title wherever the row sits and whatever the edges hold (ADR 0084, 0085). Every constraint that places or sizes the middle is below
/// the priority at which a split view's pane keeps its width, and so below the window's: no
/// content can move a divider or resize the window. When the middle can't be centered without
/// overlapping an edge view it moves aside instead, and only when nothing fits at all does it
/// overlap them.
///
/// A row that fills before it centers, as the toolbar's status is, centers on itself only, and
/// a flexible middle there takes all the width the edge views leave before it centers.
public final class CenteredRow: NSView {
    /// Keeps the middle clear of the edge views, under `NSSplitViewItem`'s lowest holding
    /// priority, 250, so content wider than the row overlaps rather than widens its pane.
    static let clearancePriority = NSLayoutConstraint.Priority(240)
    /// Under the clearance, so the middle moves aside before it overlaps.
    static let centeringPriority = NSLayoutConstraint.Priority(230)
    /// Centered in the row itself, before the row is in a window.
    static let rowCenteringPriority = NSLayoutConstraint.Priority(220)
    /// How hard text in the row resists truncation: under the centering, so text gives way
    /// before the middle moves aside.
    public static let textCompressionPriority = NSLayoutConstraint.Priority(210)
    /// The middle's pull to the row's width, under the centering, so it grows evenly to both
    /// sides until the nearer edge view stops it.
    static let fillPriority = NSLayoutConstraint.Priority(200)
    /// The middle's pull to the row's width in a row that fills before it centers: over the
    /// centering, and under `StatusColumn.equalPriority`, so flexible columns still share.
    static let fillFirstPriority = NSLayoutConstraint.Priority(213)
    /// The centering in a row that fills before it centers: under the fill, and over the text's
    /// compression resistance, so text gives way before the middle moves aside.
    static let afterFillCenteringPriority = NSLayoutConstraint.Priority(212)

    let leading: NSView
    let middle: NSView
    let trailing: NSView
    private lazy var fill: NSLayoutConstraint = {
        let fill = middle.widthAnchor.constraint(equalTo: widthAnchor)
        fill.priority = fillsBeforeCentering ? Self.fillFirstPriority : Self.fillPriority
        return fill
    }()
    /// The edge views' pulls toward the middle, under the centering, so they take the width
    /// beside it without moving it.
    private lazy var leadingFill = edgeFill(leading.trailingAnchor, middle.leadingAnchor)
    private lazy var trailingFill = edgeFill(middle.trailingAnchor, trailing.leadingAnchor)
    private let spacing: CGFloat
    private let fillsBeforeCentering: Bool
    private lazy var leadingEdge = leading.leadingAnchor.constraint(equalTo: leadingAnchor)

    /// The space between the row's leading edge and the leading view.
    public var leadingInset: CGFloat {
        get { leadingEdge.constant }
        set { leadingEdge.constant = newValue }
    }
    private var clearance: [NSLayoutConstraint] = []
    private var windowCentering: NSLayoutConstraint?
    /// The span of the content view the middle centers on when `centersFrom` is set.
    private var centeringGuide: NSLayoutGuide?

    /// A view whose leading edge starts the part of the window the middle centers on, such as
    /// the pane beside the sidebar, where AppKit centers the title; nil centers on the whole window.
    public var centersFrom: NSView? {
        didSet { if centersFrom !== oldValue { center() } }
    }

    /// Whether the middle takes all the width it can while staying centered, rather than its
    /// fitting width.
    var middleFills: Bool {
        get { fill.isActive }
        set { fill.isActive = newValue }
    }

    /// Whether the leading view reaches to the middle, rather than taking its fitting width.
    var leadingFills: Bool {
        get { leadingFill.isActive }
        set { leadingFill.isActive = newValue }
    }

    /// Whether the trailing view reaches to the middle.
    var trailingFills: Bool {
        get { trailingFill.isActive }
        set { trailingFill.isActive = newValue }
    }

    /// Whether the middle keeps the spacing from each edge view while that view is empty; an
    /// empty edge without it lets the middle reach the row's inset.
    public func spaceEdges(leading: Bool, trailing: Bool) {
        clearance[0].constant = leading ? spacing : 0
        clearance[1].constant = trailing ? -spacing : 0
    }

    private func edgeFill(_ left: NSLayoutXAxisAnchor, _ right: NSLayoutXAxisAnchor)
        -> NSLayoutConstraint
    {
        let fill = right.constraint(equalTo: left, constant: spacing)
        fill.priority = Self.fillPriority
        return fill
    }

    public init(
        leading: NSView, middle: NSView, trailing: NSView, spacing: CGFloat, inset: CGFloat,
        fillsBeforeCentering: Bool = false
    ) {
        self.leading = leading
        self.middle = middle
        self.trailing = trailing
        self.spacing = spacing
        self.fillsBeforeCentering = fillsBeforeCentering
        super.init(frame: .zero)
        for view in [leading, middle, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        let rowCentering = middle.centerXAnchor.constraint(equalTo: centerXAnchor)
        rowCentering.priority =
            fillsBeforeCentering ? Self.afterFillCenteringPriority : Self.rowCenteringPriority
        clearance = [
            middle.leadingAnchor.constraint(
                greaterThanOrEqualTo: leading.trailingAnchor, constant: spacing),
            middle.trailingAnchor.constraint(
                lessThanOrEqualTo: trailing.leadingAnchor, constant: -spacing),
        ]
        for constraint in clearance { constraint.priority = Self.clearancePriority }
        leadingInset = inset
        NSLayoutConstraint.activate(
            [
                leadingEdge,
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                rowCentering,
            ] + clearance)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        center()
    }

    private func center() {
        windowCentering?.isActive = false
        windowCentering = nil
        centeringGuide.map { $0.owningView?.removeLayoutGuide($0) }
        centeringGuide = nil
        guard !fillsBeforeCentering, let content = window?.contentView, isDescendant(of: content)
        else { return }
        var anchor = content.centerXAnchor
        if let start = centersFrom, start.isDescendant(of: content) {
            let guide = NSLayoutGuide()
            content.addLayoutGuide(guide)
            NSLayoutConstraint.activate([
                guide.leadingAnchor.constraint(equalTo: start.leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
            centeringGuide = guide
            anchor = guide.centerXAnchor
        }
        let centering = middle.centerXAnchor.constraint(equalTo: anchor)
        centering.priority = Self.centeringPriority
        centering.isActive = true
        windowCentering = centering
    }
}
