import AppKit
import Library

/// Shares of a whole as one rounded bar cut into colored parts, with a legend under it: each
/// part's name and percentage. Listening Stats draws the plays by rate group with it.
final class StatsShareBar: NSView {
    var shares: [StatsReport.Share] = [] {
        didSet { needsDisplay = true }
    }

    /// The parts' colors, in order; more parts than colors reuse them.
    static let colors: [NSColor] = [
        .controlAccentColor, .systemPurple, .systemOrange, .systemGray, .systemTeal,
    ]

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        let total = max(1, shares.reduce(0) { $0 + $1.plays })
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: 10)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).addClip()
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        bar.fill()
        var x: CGFloat = 0
        for (place, share) in shares.enumerated() {
            let width = bar.width * CGFloat(share.plays) / CGFloat(total)
            Self.colors[place % Self.colors.count].setFill()
            NSRect(x: x, y: 0, width: width, height: bar.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        var point = NSPoint(x: 0, y: bar.maxY + 6)
        for (place, share) in shares.enumerated() {
            let text = NSAttributedString(
                string: "\(share.name) \(percentText(Double(share.plays) / Double(total)))",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            let width = 12 + text.size().width
            if point.x > 0, point.x + width > bounds.width {
                point = NSPoint(x: 0, y: point.y + 16)
            }
            Self.colors[place % Self.colors.count].setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x, y: point.y + 4, width: 7, height: 7)).fill()
            text.draw(at: NSPoint(x: point.x + 11, y: point.y))
            point.x += width + 12
        }
    }

    override func accessibilityLabel() -> String? {
        let total = max(1, shares.reduce(0) { $0 + $1.plays })
        return shares.map { "\($0.name) \(percentText(Double($0.plays) / Double(total)))" }
            .joined(separator: ", ")
    }
}
