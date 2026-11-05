import AppKit
import Library

/// Plays over time as bars, one per day, week, month or year, the tallest the chart's height,
/// with the first and last bar's names under them. The bar under the pointer is drawn solid and
/// reported; a click on a bar reports it. `marked` is drawn solid too, for the busiest month.
final class StatsBarChart: NSView {
    var bars: [StatsReport.Bar] = [] {
        didSet {
            hovered = nil
            needsDisplay = true
        }
    }
    var unit = StatsReport.BarUnit.day {
        didSet { needsDisplay = true }
    }
    var marked: Int? {
        didSet { needsDisplay = true }
    }
    var calendar = Calendar.current
    var clicked: (Int) -> Void = { _ in }
    /// The bar under the pointer, or nil once it leaves.
    var hoverChanged: (Int?) -> Void = { _ in }
    private(set) var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            hoverChanged(hovered)
        }
    }

    static let axisPoints: CGFloat = 16

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                    .inVisibleRect], owner: self))
    }

    /// The area the bars are drawn in, above the axis labels.
    private var plot: NSRect {
        NSRect(x: 0, y: 12, width: bounds.width, height: max(0, bounds.height - 12 - Self.axisPoints))
    }

    /// The bar whose column holds `point`, in the view's coordinates.
    func bar(at point: NSPoint) -> Int? {
        guard !bars.isEmpty, point.x >= 0, point.x < bounds.width else { return nil }
        let place = Int(point.x / (bounds.width / CGFloat(bars.count)))
        return bars.indices.contains(place) ? place : nil
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = bar(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let place = bar(at: convert(event.locationInWindow, from: nil)) else { return }
        clicked(place)
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plot
        let most = max(1, bars.map(\.plays).max() ?? 0)
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        let labelColor = NSColor.tertiaryLabelColor
        // A line at the tallest bar's height, labeled with its plays.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: plot.minY, width: plot.width, height: 1).fill()
        NSRect(x: 0, y: plot.maxY, width: plot.width, height: 1).fill()
        NSAttributedString(
            string: number(most), attributes: [.font: small, .foregroundColor: labelColor]
        ).draw(at: NSPoint(x: 0, y: 0))
        guard !bars.isEmpty else { return }
        let step = plot.width / CGFloat(bars.count)
        let gap = step >= 6 ? max(1, min(4, step * 0.2)) : 0
        let accent = NSColor.controlAccentColor
        for (place, bar) in bars.enumerated() {
            let height = plot.height * CGFloat(bar.plays) / CGFloat(most)
            let frame = NSRect(
                x: CGFloat(place) * step + gap / 2, y: plot.maxY - height,
                width: max(1, step - gap), height: height)
            let solid = place == hovered || place == marked
            if place == hovered {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).setFill()
                NSRect(x: CGFloat(place) * step, y: plot.minY, width: step, height: plot.height).fill()
            }
            guard bar.plays > 0 else { continue }
            accent.withAlphaComponent(solid ? 1 : 0.6).setFill()
            let radius = min(2, frame.width / 2)
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: labelColor]
        let first = NSAttributedString(
            string: barTitle(bars[0], unit: unit, calendar: calendar), attributes: attributes)
        first.draw(at: NSPoint(x: 0, y: plot.maxY + 3))
        if bars.count > 1 {
            let last = NSAttributedString(
                string: barTitle(bars[bars.count - 1], unit: unit, calendar: calendar),
                attributes: attributes)
            let width = last.size().width
            if width + first.size().width + 12 < bounds.width {
                last.draw(at: NSPoint(x: bounds.width - width, y: plot.maxY + 3))
            }
        }
    }

    override func accessibilityLabel() -> String? {
        let busiest = bars.max { $0.plays < $1.plays }
        return busiest.map {
            "\(barsTitle(unit)): most in \(barTitle($0, unit: unit, calendar: calendar)), \(count($0.plays, "play"))"
        }
    }
}
