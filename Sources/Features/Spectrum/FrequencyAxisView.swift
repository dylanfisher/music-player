import Analysis
import AppKit
import DisplayText

/// A chart with frequency up, linear from 0 to `topHz`, and dotted lines at `referenceHz`
/// labeled at the left. Reports the pointer as shares of the plot across and up, from 0 to 1.
class FrequencyAxisView: NSView {
    var topHz = 22_050.0 {
        didSet { needsDisplay = true }
    }
    var referenceHz: [Double] = [] {
        didSet { needsDisplay = true }
    }
    /// The pointer's place in the plot, or nil once it leaves.
    var pointerMoved: ((x: Double, y: Double)?) -> Void = { _ in }

    static let leftPoints: CGFloat = 46
    static let bottomPoints: CGFloat = 16
    static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// Where the chart is drawn, inside the labels.
    var plot: NSRect {
        NSRect(
            x: Self.leftPoints, y: Self.bottomPoints,
            width: max(0, bounds.width - Self.leftPoints - 4),
            height: max(0, bounds.height - Self.bottomPoints - 6))
    }

    /// The height in the plot of `hertz`.
    func y(_ hertz: Double) -> CGFloat {
        plot.minY + plot.height * CGFloat(min(1, hertz / topHz))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackMouseMoves()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let plot = plot
        guard plot.width > 0, plot.height > 0, plot.contains(point) else {
            return pointerMoved(nil)
        }
        pointerMoved(
            (
                Double((point.x - plot.minX) / plot.width),
                Double((point.y - plot.minY) / plot.height)
            ))
    }

    override func mouseExited(with event: NSEvent) { pointerMoved(nil) }

    /// The dotted reference lines over the plot, and the axis's labels at the left: each line's
    /// frequency, 0 and the top.
    func drawFrequencyAxis(lineColor: NSColor) {
        let plot = plot
        for hertz in referenceHz {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y(hertz)))
            path.line(to: NSPoint(x: plot.maxX, y: y(hertz)))
            path.setLineDash([2, 3], count: 2, phase: 0)
            path.lineWidth = 1
            lineColor.setStroke()
            path.stroke()
        }
        let labels =
            [(0.0, "0")] + referenceHz.map { ($0, "\(kilohertzText($0))") } + [
                (topHz, "\(kilohertzText(topHz)) kHz")
            ]
        var lastTop = -CGFloat.infinity
        for (hertz, text) in labels {
            let label = NSAttributedString(string: text, attributes: Self.labelAttributes)
            let size = label.size()
            let bottom = min(plot.maxY - size.height / 2, max(0, y(hertz) - size.height / 2))
            // Lines close together keep the label under them.
            guard bottom >= lastTop else { continue }
            label.draw(at: NSPoint(x: plot.minX - size.width - 4, y: bottom))
            lastTop = bottom + size.height
        }
    }
}
