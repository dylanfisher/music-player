import AppKit
import KeyChord
import Settings

/// The bar builder's preview: the bar's columns drawn across the view, each part a chip, and
/// under them a tray of the parts the bar doesn't show. Chips drag between columns and to and
/// from the tray, the others moving aside as the drag goes to show where it will land; a click
/// selects a part or a column. A side column drags by the handle at its top to another place,
/// the others moving aside as well; the center column stays where it is. With the keys, ← and → select, ⌘← and
/// ⌘→ move the selected part, and Delete takes it out of the bar (ADR 0085).
@MainActor
final class BarBuilderView: NSView {
    static let chipPoints = 20.0
    static let trayPoints = 44.0
    private static let chipPadding = 8.0
    private static let chipSpacing = 4.0
    private static let columnPadding = 4.0
    /// The strip at the top of the bar that holds the side columns' handles.
    static let handlePoints = 10.0
    private static let handleWidth = 24.0
    private static let emptyColumnPoints = 90.0
    private static let emptyText = "Drop a part here"
    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    let model: BarBuilderModel
    private let preview = BarPreview(spacing: 10, inset: 10)
    /// The chip being dragged, and where the pointer is, once it has moved.
    private var pressed: String?
    /// The column whose handle is being dragged.
    private var pressedColumn: BarPlace?
    private var dragPoint: NSPoint?

    /// A chip as drawn: its part, its frame, and its column, or nil in the tray.
    struct Chip {
        var part: String
        var frame: NSRect
        var place: BarPlace?
    }

    /// Where a dragged part lands: at an index among a column's other parts, or in the tray.
    enum Landing: Equatable {
        case column(BarPlace, Int)
        case tray
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

    /// The bar's height: the handles' strip over one row of chips, or the tallest stacked
    /// column, up to the bar's own cap.
    var barHeight: Double {
        let tallest = model.layout.columns.filter(\.column.stacks).map(\.column.parts.count).max()
        let stacked = Double(tallest ?? 0) * (Self.chipPoints + Self.chipSpacing)
        let height = max(StatusBarStyle.tallPoints, stacked + 2 * Self.columnPadding)
        return (model.bar.stackCapPoints.map { min(height, $0) } ?? height) + Self.handlePoints
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

    /// The layout drawn: the model's, or while a part is dragged, the layout it would make if
    /// let go here, unless that layout has a problem.
    var shown: BarLayout<String> {
        if let pressedColumn, let dragPoint {
            return model.moving(pressedColumn, to: landing(of: pressedColumn, atX: dragPoint.x))
        }
        guard let pressed, let dragPoint, let landing = landing(of: pressed, at: dragPoint)
        else { return model.layout }
        let layout =
            switch landing {
            case .tray: model.removing(pressed)
            case .column(let place, let index): model.placing(pressed, in: place, at: index)
            }
        return model.problem(in: layout) == nil ? layout : model.layout
    }

    /// Every column's frame in the bar as drawn, by place.
    var columnFrames: [BarPlace: NSRect] { columnFrames(of: shown) }

    private func columnFrames(of layout: BarLayout<String>) -> [BarPlace: NSRect] {
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

    /// Every chip as drawn, in its column or in the tray.
    var chips: [Chip] { chips(of: shown) }

    private func chips(of layout: BarLayout<String>) -> [Chip] {
        var chips: [Chip] = []
        let frames = columnFrames(of: layout)
        for (place, column) in layout.columns {
            guard let frame = frames[place] else { continue }
            chips += self.chips(column, in: frame).map { Chip(part: $0, frame: $1, place: place) }
        }
        var x = preview.inset
        for part in model.unusedParts(in: layout) {
            let width = chipWidth(part)
            let y = trayFrame.midY - Self.chipPoints / 2
            chips.append(
                Chip(part: part, frame: NSRect(x: x, y: y, width: width, height: Self.chipPoints)))
            x += width + Self.chipSpacing
        }
        return chips
    }

    private func chips(_ column: BarColumn<String>, in frame: NSRect) -> [(String, NSRect)] {
        var inner = frame.insetBy(dx: Self.columnPadding, dy: Self.columnPadding)
        inner.origin.y += Self.handlePoints
        inner.size.height -= Self.handlePoints
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
        let layout = shown
        let frames = columnFrames(of: layout)
        // Where a dragged column is drawn, outlined as selected.
        let draggedColumn = pressedColumn.flatMap { column in
            dragPoint.map { landing(of: column, atX: $0.x) }
        }
        for (place, column) in layout.columns {
            guard let frame = frames[place] else { continue }
            let path = NSBezierPath(
                roundedRect: frame.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5)
            let selected =
                draggedColumn.map { $0 == place }
                ?? (model.selection.place == place && model.selection.part == nil)
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = selected ? 2 : 1
            if place == .center { path.setLineDash([4, 2], count: 2, phase: 0) }
            path.stroke()
            if column.parts.isEmpty {
                drawText(Self.emptyText, in: frame, color: .secondaryLabelColor)
            }
            if place != .center { drawHandle(in: handleFrame(frame)) }
        }
        if model.unusedParts(in: layout).isEmpty {
            drawText("Every part is in the bar", in: trayFrame, color: .secondaryLabelColor)
        }
        let selected = model.selection.part.flatMap { model.selectedColumn?.parts[$0] }
        for chip in chips(of: layout) {
            // A stack taller than the bar's cap is clipped, as the bar clips it.
            NSGraphicsContext.saveGraphicsState()
            if chip.place != nil {
                NSRect(x: 0, y: 0, width: bounds.width, height: barHeight).clip()
            }
            if chip.part == pressed, dragPoint != nil {
                // The room the dragged part will take.
                let hole = NSBezierPath(
                    roundedRect: chip.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                hole.setLineDash([3, 2], count: 2, phase: 0)
                NSColor.separatorColor.setStroke()
                hole.stroke()
            } else {
                drawChip(
                    chip.part, in: chip.frame, selected: chip.place != nil && chip.part == selected)
            }
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

    /// Three short lines, as a grab handle.
    private func drawHandle(in frame: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for line in 0..<3 {
            NSRect(
                x: frame.minX + 4, y: frame.minY + 2 + Double(line) * 2.5, width: frame.width - 8,
                height: 1
            )
            .fill()
        }
    }

    /// The handle at the top of a side column's frame.
    private func handleFrame(_ column: NSRect) -> NSRect {
        NSRect(
            x: column.midX - Self.handleWidth / 2, y: 2, width: Self.handleWidth,
            height: Self.handlePoints)
    }

    /// Each side column's handle, by place.
    var handleFrames: [BarPlace: NSRect] {
        columnFrames.filter { $0.key != .center }.mapValues(handleFrame)
    }

    override func resetCursorRects() {
        for frame in handleFrames.values { addCursorRect(frame, cursor: .openHand) }
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
        pressedColumn = handleFrames.first { $0.value.contains(point) }?.key
        pressed = pressedColumn == nil ? chips.first { $0.frame.contains(point) }?.part : nil
        if let pressedColumn {
            model.select(.init(place: pressedColumn))
        } else if let chip = chips.first(where: { $0.frame.contains(point) }),
            let place = chip.place
        {
            model.select(
                .init(place: place, part: model.layout[place]?.parts.firstIndex(of: chip.part)))
        } else if let place = columnFrames.first(where: { $0.value.contains(point) })?.key {
            model.select(.init(place: place))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let pressedColumn { return dragColumn(pressedColumn, to: point) }
        guard let pressed else { return }
        drag(pressed, to: point)
    }

    /// Shows the column at `place` dragged to `point`, the others moved aside for it.
    func dragColumn(_ place: BarPlace, to point: NSPoint) {
        pressedColumn = place
        dragPoint = point
        needsDisplay = true
    }

    /// Shows `part` dragged to `point`, the others moved aside for it.
    func drag(_ part: String, to point: NSPoint) {
        pressed = part
        dragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            pressedColumn = nil
            dragPoint = nil
            needsDisplay = true
        }
        guard dragPoint != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let pressedColumn {
            model.moveColumn(pressedColumn, to: landing(of: pressedColumn, atX: point.x))
        } else if let pressed {
            drop(pressed, at: point)
        }
    }

    /// Where the side column at `place` lands let go at `x`: left of the center column's middle
    /// among the leading columns, right of it among the trailing ones, after each column of
    /// that side whose middle is left of `x`. It's measured on the layout without the column.
    func landing(of place: BarPlace, atX x: Double) -> BarPlace {
        var without = model.layout
        switch place {
        case .center: return place
        case .leading(let index): without.leading.remove(at: index)
        case .trailing(let index): without.trailing.remove(at: index)
        }
        let frames = columnFrames(of: without)
        let before = { (place: BarPlace) in (frames[place]?.midX ?? 0) < x }
        if x < frames[.center]?.midX ?? 0 {
            return .leading(without.leading.indices.map(BarPlace.leading).filter(before).count)
        }
        return .trailing(without.trailing.indices.map(BarPlace.trailing).filter(before).count)
    }

    /// Puts `part` where a drag let go of it at `point`.
    func drop(_ part: String, at point: NSPoint) {
        switch landing(of: part, at: point) {
        case .tray: model.remove(part)
        case .column(let place, let index): model.place(part, in: place, at: index)
        case nil: break
        }
    }

    /// Where `part` lands let go at `point`: in the column there, before the first of its
    /// other chips whose middle is past the point, or in the tray. It's measured on the layout
    /// without the part, which stays still while the drag moves the others aside.
    func landing(of part: String, at point: NSPoint) -> Landing? {
        if trayFrame.contains(point) { return .tray }
        let without = model.removing(part)
        guard let (place, _) = columnFrames(of: without).first(where: { $0.value.contains(point) }),
            let column = without[place]
        else { return nil }
        let others = chips(of: without).filter { $0.place == place }
        let index =
            others.firstIndex { chip in
                column.stacks ? chip.frame.midY > point.y : chip.frame.midX > point.x
            } ?? others.count
        return .column(place, index)
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
