import AppKit
import KeyChord
import Settings

/// The bar builder's preview: the bar's columns drawn across the view, each part a chip, and
/// under them a tray of the parts the bar doesn't show. Chips drag between columns and to and
/// from the tray; a click selects a part or a column. With the keys, ← and → select, ⌘← and
/// ⌘→ move the selected part, and Delete takes it out of the bar (ADR 0085).
@MainActor
final class BarBuilderView: NSView {
    static let chipPoints = 20.0
    static let trayPoints = 44.0
    private static let chipPadding = 8.0
    private static let chipSpacing = 4.0
    private static let columnPadding = 4.0
    private static let emptyColumnPoints = 90.0
    private static let emptyText = "Drop a part here"
    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    let model: BarBuilderModel
    private let preview = BarPreview(spacing: 10, inset: 10)
    /// The chip being dragged, and where the pointer is, once it has moved.
    private var pressed: String?
    private var dragPoint: NSPoint?

    /// A chip as drawn: its part, its frame, and its column, or nil in the tray.
    struct Chip {
        var part: String
        var frame: NSRect
        var place: BarPlace?
    }

    init(model: BarBuilderModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel(model.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    /// The bar's height: one row of chips, or the tallest stacked column, up to the bar's own
    /// cap.
    var barHeight: Double {
        let tallest = model.layout.columns.filter(\.column.stacks).map(\.column.parts.count).max()
        let stacked = Double(tallest ?? 0) * (Self.chipPoints + Self.chipSpacing)
        let height = max(StatusBarStyle.tallPoints, stacked + 2 * Self.columnPadding)
        return model.bar.stackCapPoints.map { min(height, $0) } ?? height
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight + Self.trayPoints)
    }

    private func chipWidth(_ part: String) -> Double {
        let text = model.title(of: part) as NSString
        return text.size(withAttributes: [.font: Self.font]).width + 2 * Self.chipPadding
    }

    private func natural(_ column: BarColumn<String>) -> Double {
        guard !column.parts.isEmpty else { return Self.emptyColumnPoints }
        let widths = column.parts.map(chipWidth)
        let content =
            column.stacks
            ? widths.max() ?? 0
            : widths.reduce(0, +) + Double(widths.count - 1) * Self.chipSpacing
        return content + 2 * Self.columnPadding
    }

    /// Every column's frame in the bar, by place.
    var columnFrames: [BarPlace: NSRect] {
        let layout = model.layout
        let spans = preview.columns(of: layout, width: bounds.width) { place in
            layout[place].map(natural) ?? 0
        }
        return spans.mapValues { span in
            NSRect(x: span.x, y: 0, width: span.width, height: barHeight)
        }
    }

    var trayFrame: NSRect {
        NSRect(x: 0, y: barHeight, width: bounds.width, height: Self.trayPoints)
    }

    /// Every chip, in its column or in the tray.
    var chips: [Chip] {
        var chips: [Chip] = []
        let frames = columnFrames
        for (place, column) in model.layout.columns {
            guard let frame = frames[place] else { continue }
            chips += self.chips(column, in: frame).map { Chip(part: $0, frame: $1, place: place) }
        }
        var x = preview.inset
        for part in model.unusedParts {
            let width = chipWidth(part)
            let y = trayFrame.midY - Self.chipPoints / 2
            chips.append(
                Chip(part: part, frame: NSRect(x: x, y: y, width: width, height: Self.chipPoints)))
            x += width + Self.chipSpacing
        }
        return chips
    }

    private func chips(_ column: BarColumn<String>, in frame: NSRect) -> [(String, NSRect)] {
        let inner = frame.insetBy(dx: Self.columnPadding, dy: Self.columnPadding)
        let widths = column.parts.map(chipWidth)
        func x(_ width: Double) -> Double {
            switch column.alignment {
            case .leading: inner.minX
            case .center: inner.midX - width / 2
            case .trailing: inner.maxX - width
            }
        }
        if column.stacks {
            let height =
                Double(widths.count) * (Self.chipPoints + Self.chipSpacing) - Self.chipSpacing
            var y = inner.midY - height / 2
            return zip(column.parts, widths).map { part, width in
                defer { y += Self.chipPoints + Self.chipSpacing }
                return (part, NSRect(x: x(width), y: y, width: width, height: Self.chipPoints))
            }
        }
        let total = widths.reduce(0, +) + Double(max(widths.count - 1, 0)) * Self.chipSpacing
        var left = x(total)
        let y = inner.midY - Self.chipPoints / 2
        return zip(column.parts, widths).map { part, width in
            defer { left += width + Self.chipSpacing }
            return (part, NSRect(x: left, y: y, width: width, height: Self.chipPoints))
        }
    }

    // MARK: Drawing

    /// Drawn in the settings window's own colors: the bar as a section's box, each column
    /// outlined as the box is, and each part as a shortcut recorder's field.
    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: barHeight).insetBy(
                dx: 0.5, dy: 0.5), xRadius: GeneralPane.boxCornerRadius,
            yRadius: GeneralPane.boxCornerRadius)
        GeneralPane.boxFill.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.stroke()
        let frames = columnFrames
        for (place, column) in model.layout.columns {
            guard let frame = frames[place] else { continue }
            let path = NSBezierPath(
                roundedRect: frame.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5)
            let selected = model.selection.place == place && model.selection.part == nil
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = selected ? 2 : 1
            if place == .center { path.setLineDash([4, 2], count: 2, phase: 0) }
            path.stroke()
            if column.parts.isEmpty {
                drawText(Self.emptyText, in: frame, color: .secondaryLabelColor)
            }
        }
        if model.unusedParts.isEmpty {
            drawText("Every part is in the bar", in: trayFrame, color: .secondaryLabelColor)
        }
        for chip in chips where !(chip.part == pressed && dragPoint != nil) {
            // A stack taller than the bar's cap is clipped, as the bar clips it.
            NSGraphicsContext.saveGraphicsState()
            if chip.place != nil {
                NSRect(x: 0, y: 0, width: bounds.width, height: barHeight).clip()
            }
            drawChip(chip.part, in: chip.frame, selected: isSelected(chip))
            NSGraphicsContext.restoreGraphicsState()
        }
        if let pressed, let dragPoint {
            let width = chipWidth(pressed)
            drawChip(
                pressed,
                in: NSRect(
                    x: dragPoint.x - width / 2, y: dragPoint.y - Self.chipPoints / 2, width: width,
                    height: Self.chipPoints), selected: true)
        }
    }

    private func isSelected(_ chip: Chip) -> Bool {
        guard let place = chip.place, let index = model.selection.part else { return false }
        return place == model.selection.place && model.layout[place]?.parts[index] == chip.part
    }

    private func drawChip(_ part: String, in frame: NSRect, selected: Bool) {
        let path = NSBezierPath(
            roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (selected ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill()
        path.fill()
        if !selected {
            NSColor.separatorColor.setStroke()
            path.stroke()
        }
        drawText(
            model.title(of: part), in: frame,
            color: selected ? .alternateSelectedControlTextColor : .labelColor)
    }

    private func drawText(_ text: String, in frame: NSRect, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
            withAttributes: attributes)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragPoint = nil
        pressed = chips.first { $0.frame.contains(point) }?.part
        if let chip = chips.first(where: { $0.frame.contains(point) }), let place = chip.place {
            model.select(
                .init(place: place, part: model.layout[place]?.parts.firstIndex(of: chip.part)))
        } else if let place = columnFrames.first(where: { $0.value.contains(point) })?.key {
            model.select(.init(place: place))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed != nil else { return }
        dragPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            dragPoint = nil
            needsDisplay = true
        }
        guard let part = pressed, dragPoint != nil else { return }
        drop(part, at: convert(event.locationInWindow, from: nil))
    }

    /// Puts `part` where a drag let go of it at `point`: in the column there, before the first
    /// chip whose middle is past the point, or back in the tray.
    func drop(_ part: String, at point: NSPoint) {
        if trayFrame.contains(point) { return model.remove(part) }
        guard let (place, _) = columnFrames.first(where: { $0.value.contains(point) }),
            let column = model.layout[place]
        else { return }
        let others = chips.filter { $0.place == place }
        let index =
            others.firstIndex { chip in
                column.stacks ? chip.frame.midY > point.y : chip.frame.midX > point.x
            } ?? others.count
        model.place(part, in: place, at: index)
    }

    // MARK: Keys

    /// Takes the arrows and Delete before the menus do, which play the previous and next track
    /// on them, while the preview has the keys.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        return handle(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch KeyChord(event: event) {
        case KeyChord(.left): model.selectNext(false)
        case KeyChord(.right): model.selectNext(true)
        case KeyChord(.left, .command): model.moveSelected(false)
        case KeyChord(.right, .command): model.moveSelected(true)
        case KeyChord(.delete): model.removeSelected()
        default: return false
        }
        return true
    }
}
