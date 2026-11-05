import AppKit
import Library

/// Plays by weekday and hour as a grid: a row per weekday from the calendar's first, a column
/// per hour, each cell the accent color as strong as its share of the busiest cell. The cell
/// under the pointer is reported.
final class StatsHeatGrid: NSView {
    /// `weekdayHours[weekday - 1][hour]`, as `StatsReport` keeps it.
    var weekdayHours = Array(repeating: Array(repeating: 0, count: 24), count: 7) {
        didSet { needsDisplay = true }
    }
    var calendar = Calendar.current {
        didSet { needsDisplay = true }
    }
    /// The weekday (1 is Sunday) and hour under the pointer, or nil once it leaves.
    var hoverChanged: ((weekday: Int, hour: Int)?) -> Void = { _ in }
    private var hovered: (weekday: Int, hour: Int)? {
        didSet {
            guard hovered?.weekday != oldValue?.weekday || hovered?.hour != oldValue?.hour else {
                return
            }
            needsDisplay = true
            hoverChanged(hovered)
        }
    }

    private static let labelPoints: CGFloat = 30
    private static let axisPoints: CGFloat = 14

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// The weekdays top to bottom, from the calendar's first.
    var weekdays: [Int] { (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 } }

    private var cellSize: NSSize {
        NSSize(
            width: max(0, bounds.width - Self.labelPoints) / 24,
            height: max(0, bounds.height - Self.axisPoints) / 7)
    }

    /// The weekday and hour of the cell at `point`.
    func cell(at point: NSPoint) -> (weekday: Int, hour: Int)? {
        let size = cellSize
        guard size.width > 0, size.height > 0, point.x >= Self.labelPoints, point.y >= 0 else {
            return nil
        }
        let hour = Int((point.x - Self.labelPoints) / size.width)
        let row = Int(point.y / size.height)
        guard (0..<24).contains(hour), (0..<7).contains(row) else { return nil }
        return (weekdays[row], hour)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                    .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = cell(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func draw(_ dirtyRect: NSRect) {
        let size = cellSize
        let most = max(1, weekdayHours.joined().max() ?? 0)
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: small, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let accent = NSColor.controlAccentColor
        let names = calendar.shortWeekdaySymbols
        for (row, weekday) in weekdays.enumerated() {
            let y = CGFloat(row) * size.height
            NSAttributedString(string: names[weekday - 1], attributes: attributes)
                .draw(at: NSPoint(x: 0, y: y + (size.height - small.pointSize) / 2 - 2))
            for hour in 0..<24 {
                let plays = weekdayHours[weekday - 1][hour]
                let frame = NSRect(
                    x: Self.labelPoints + CGFloat(hour) * size.width + 1, y: y + 1,
                    width: max(1, size.width - 2), height: max(1, size.height - 2))
                let color =
                    plays == 0
                    ? NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                    : accent.withAlphaComponent(0.15 + 0.85 * CGFloat(plays) / CGFloat(most))
                color.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2).fill()
                if hovered?.weekday == weekday, hovered?.hour == hour {
                    NSColor.labelColor.setStroke()
                    NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2).stroke()
                }
            }
        }
        for hour in stride(from: 0, to: 24, by: 6) {
            NSAttributedString(string: hourName(hour), attributes: attributes).draw(
                at: NSPoint(
                    x: Self.labelPoints + CGFloat(hour) * size.width, y: 7 * size.height + 1))
        }
    }

    override func accessibilityLabel() -> String? {
        var best = (weekday: 1, hour: 0, plays: 0)
        for weekday in 1...7 {
            for hour in 0..<24 where weekdayHours[weekday - 1][hour] > best.plays {
                best = (weekday, hour, weekdayHours[weekday - 1][hour])
            }
        }
        guard best.plays > 0 else { return "No plays" }
        return "Most plays on \(calendar.weekdaySymbols[best.weekday - 1]) at \(hourName(best.hour))"
    }

    /// "18:00" or "6 PM", as the locale writes an hour.
    func hourName(_ hour: Int) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.setLocalizedDateFormatFromTemplate("j")
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour))
        return date.map(format.string(from:)) ?? "\(hour)"
    }
}
