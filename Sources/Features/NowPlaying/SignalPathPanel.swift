import AppKit
import Playback

/// A strip under the now-playing bar showing what happens to the samples between the file and the
/// device, with the verdict on top. The app hands it each path the output publishes.
@MainActor
public final class SignalPathPanel: NSViewController {
    private let verdictLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    /// Made again for each path: `NSGridView.removeRow` leaves the row's views in the grid,
    /// where they draw under the new rows.
    private(set) var grid = NSGridView()

    public init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override public func loadView() {
        verdictLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        verdictLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.setViews([verdictLabel, grid], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.setClippingResistancePriority(.required, for: .vertical)
        view = stack
        show(nil)
    }

    /// Shows `path`, or no output when it's nil.
    public func show(_ path: SignalPath?) {
        _ = view
        let lines = signalPathLines(path)
        verdictLabel.stringValue = lines.verdict
        verdictLabel.textColor = lines.isBitPerfect ? .systemGreen : .labelColor
        let fresh = NSGridView()
        fresh.rowSpacing = 2
        fresh.columnSpacing = 8
        stack.removeView(grid)
        stack.addView(fresh, in: .top)
        grid = fresh
        for row in lines.rows {
            let label = NSTextField(labelWithString: row.label)
            let value = NSTextField(labelWithString: row.value)
            label.textColor = .secondaryLabelColor
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.toolTip = row.value
            for field in [label, value] {
                field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            }
            grid.addRow(with: [label, value])
        }
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
    }
}
