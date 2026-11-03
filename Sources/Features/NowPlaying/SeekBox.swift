import AppKit

/// The seek bar between the elapsed time and the track's length, in a rounded inset box, as the
/// toolbar and the status bar show it. A mouse down anywhere in the box never moves the window:
/// both sit where a window can be dragged by its background, the toolbar and, with glass, a
/// full-size content view.
@MainActor
final class SeekBox: NSView {
    static let heightPoints = 18.0
    static let cornerPoints = 5.0
    /// Between the box's edge and the times, and between the times and the bar.
    static let insetPoints = 6.0
    static let fontPoints = NSFont.smallSystemFontSize

    let bar = SeekBar()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let font = NSFont.monospacedDigitSystemFont(ofSize: Self.fontPoints, weight: .regular)
        // Wide enough for any time under 100 minutes, so the bar doesn't move as they count.
        let timePoints = ("00:00" as NSString).size(withAttributes: [.font: font]).width.rounded(
            .up)
        for label in [elapsedLabel, totalLabel] {
            label.font = font
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: timePoints).isActive = true
            addSubview(label)
        }
        elapsedLabel.alignment = .right
        totalLabel.alignment = .left
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        let inset = Self.insetPoints
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.heightPoints),
            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            bar.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: inset),
            totalLabel.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: totalLabel.trailingAnchor, constant: inset),
            elapsedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            totalLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    func showTimes(elapsed: String, total: String) {
        elapsedLabel.stringValue = elapsed
        totalLabel.stringValue = total
    }

    /// The times shown, for tests.
    var times: (elapsed: String, total: String) {
        (elapsedLabel.stringValue, totalLabel.stringValue)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The times take no clicks, so a click on them lands on the box, which ignores it, rather
    /// than on a label, which would let it move the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === bar ? bar : self
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: box, xRadius: Self.cornerPoints, yRadius: Self.cornerPoints)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
