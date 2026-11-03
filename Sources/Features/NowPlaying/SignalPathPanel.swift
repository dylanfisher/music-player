import AppKit
import Playback

/// A strip under the now-playing bar showing what happens to the samples between the file and the
/// device: the verdict as a badge on top, the stages in two columns under it. The app hands it
/// each path the output publishes.
@MainActor
public final class SignalPathPanel: NSViewController {
    let badge = BadgeBackground()
    let badgeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let columns = NSStackView()
    /// Made again for each path: `NSGridView.removeRow` leaves the row's views in the grid,
    /// where they draw under the new rows.
    private(set) var grids: [NSGridView] = []

    public init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override public func loadView() {
        badgeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        // A plain view under constraints: an `NSBox` sizes itself from its content view, not
        // from constraints on a label added beside it, and cut the label off.
        badge.addSubview(badgeLabel)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            badgeLabel.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1),
        ])
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let verdict = NSStackView(views: [badge, detailLabel])
        verdict.alignment = .top
        verdict.spacing = 6
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 20
        let stack = NSStackView(views: [verdict, columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.setClippingResistancePriority(.required, for: .vertical)
        for view in [verdict, columns] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -stack.edgeInsets.left - stack.edgeInsets.right
            ).isActive = true
        }
        view = stack
        show(nil)
    }

    /// Shows `path`, or no output when it's nil.
    public func show(_ path: SignalPath?) {
        _ = view
        let lines = signalPathLines(path)
        badgeLabel.stringValue = lines.badge
        let color: NSColor =
            switch lines.tone {
            case .bitPerfect: .systemGreen
            case .changed: .systemOrange
            case .neutral: .secondaryLabelColor
            }
        badgeLabel.textColor = color
        badge.color = color.withAlphaComponent(0.15)
        detailLabel.stringValue = lines.detail
        detailLabel.isHidden = lines.detail.isEmpty
        grids = lines.columns.map(grid)
        columns.setViews(grids.map(half), in: .leading)
    }

    /// Holds `grid` at the leading edge of half the panel. A grid stretched to the half gives the
    /// spare width to its label column, and a grid in the stack on its own keeps its own width,
    /// so the right column starts wherever the left one ends.
    private func half(_ grid: NSGridView) -> NSView {
        let half = NSView()
        half.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: half.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: half.trailingAnchor),
            grid.topAnchor.constraint(equalTo: half.topAnchor),
            grid.bottomAnchor.constraint(equalTo: half.bottomAnchor),
        ])
        return half
    }

    private func grid(_ rows: [SignalPathLines.Row]) -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing = 2
        grid.columnSpacing = 8
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            let value = NSTextField(labelWithString: row.value)
            label.textColor = .secondaryLabelColor
            value.lineBreakMode = .byTruncatingTail
            // Above the grid's own hugging, so a value shows in full while its half has room, and
            // below a window resize, so it truncates instead of holding the window wide.
            value.setContentCompressionResistancePriority(.init(490), for: .horizontal)
            value.toolTip = row.value
            for field in [label, value] {
                field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            }
            grid.addRow(with: [label, value])
        }
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
        return grid
    }
}

/// The verdict badge's rounded fill, in a color that follows the appearance.
final class BadgeBackground: NSView {
    var color = NSColor.clear {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
