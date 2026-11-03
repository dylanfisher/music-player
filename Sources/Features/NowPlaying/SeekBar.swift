import AppKit

/// A seek bar: a rounded track filled in the accent color up to the position. A click moves the
/// position there at once and seeks, with no animation; a drag moves it with the pointer and
/// seeks where it's let go.
@MainActor
final class SeekBar: NSView {
    static let trackPoints = 4.0
    static let heightPoints = 12.0

    /// The position, from 0 to 1.
    var fraction = 0.0 {
        didSet { needsDisplay = true }
    }
    var isEnabled = true {
        didSet {
            if !isEnabled { cancelTracking() }
            needsDisplay = true
        }
    }
    /// Called with the fraction under the pointer: `done` is false while a drag goes on, and
    /// true on a click and where a drag ends, where the track should seek to.
    var seek: (_ fraction: Double, _ done: Bool) -> Void = { _, _ in }
    /// Whether the pointer holds the position, so the position shown leaves it alone.
    private(set) var isTracking = false
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setContentHuggingPriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.heightPoints)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The fraction under `x`, in a bar `width` points wide, held between 0 and 1.
    nonisolated static func fraction(atX x: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(x / width, 0), 1)
    }

    func press(atX x: Double) {
        guard isEnabled else { return }
        isTracking = true
        moved = false
        fraction = Self.fraction(atX: x, width: bounds.width)
        seek(fraction, true)
    }

    func drag(toX x: Double) {
        guard isTracking else { return }
        moved = true
        fraction = Self.fraction(atX: x, width: bounds.width)
        seek(fraction, false)
    }

    /// Lets go of the position without seeking, as when the track changes under a drag.
    func cancelTracking() {
        isTracking = false
        moved = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Taken out of the window mid-drag, it would never see the mouse up.
        if window == nil { cancelTracking() }
    }

    func release() {
        guard isTracking else { return }
        isTracking = false
        // A click already sought on the press.
        if moved { seek(fraction, true) }
    }

    override func mouseDown(with event: NSEvent) {
        press(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(toX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { release() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.trackPoints / 2
        let track = NSRect(
            x: bounds.minX, y: bounds.midY - radius, width: bounds.width, height: Self.trackPoints)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard isEnabled, fraction > 0 else { return }
        var played = track
        // At least a round end's width, so the start of a track still shows as played.
        played.size.width = max(track.width * fraction, Self.trackPoints)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: played, xRadius: radius, yRadius: radius).fill()
    }

    override func accessibilityValue() -> Any? { fraction }
}
