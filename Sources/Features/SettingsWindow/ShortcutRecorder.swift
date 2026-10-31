import AppKit
import KeyChord

/// A field that records one shortcut slot. A click, or Space or Return while it has the keys,
/// starts recording; the next key press is taken by a local event monitor, which runs before the
/// menus' key equivalents and swallows the press, so recording never runs a command. Esc
/// cancels, Delete removes the chord. Recording ends, and the monitor goes, when a key is taken
/// or the field loses the keys, its window, or its window's key status.
@MainActor
final class ShortcutRecorder: NSControl {
    var chord: KeyChord? {
        didSet { needsDisplay = true }
    }
    var recorded: (KeyChord) -> Void = { _ in }
    var removed: () -> Void = {}
    private(set) var isRecording = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(valueText)
        }
    }
    private var monitor: Any?
    private var hovering = false
    private var pressed = false
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
        setAccessibilityRole(.button)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 22) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    private var valueText: String {
        isRecording ? "Type Shortcut" : chord?.symbols ?? "None"
    }

    // MARK: Drawing: hover, pressed, focused, recording and off each look different

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        if isEnabled {
            let fill: NSColor =
                pressed
                ? .tertiaryLabelColor : hovering ? .quaternaryLabelColor : .controlBackgroundColor
            fill.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        if isRecording {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
        let color: NSColor =
            !isEnabled
            ? .tertiaryLabelColor : isRecording || chord == nil ? .secondaryLabelColor : .labelColor
        let text = NSAttributedString(
            string: valueText,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: color,
            ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            needsDisplay = true
            return
        }
        window?.makeFirstResponder(self)
        startRecording()
    }

    override func keyDown(with event: NSEvent) {
        let chord = KeyChord(event: event)
        if chord == KeyChord(.space) || chord == KeyChord(.return) {
            startRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        startRecording()
        return true
    }

    // MARK: Recording

    func startRecording() {
        guard isEnabled, !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Nil swallows the press, so no menu or view sees it.
            guard let self else { return event }
            return MainActor.assumeIsolated { self.take(event) } ? nil : event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main)
                {
                    [weak self] _ in MainActor.assumeIsolated { self?.stopRecording() }
                })
        }
    }

    /// Whether the monitor swallows the press: always, while recording.
    private func take(_ event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else {
            stopRecording()
            return false
        }
        // A held key's repeats are swallowed and not recorded.
        if event.isARepeat { return true }
        let candidates = KeyChord.candidates(for: event)
        guard let first = candidates.first else { return true }
        if first == KeyChord(.escape) {
            stopRecording()
        } else if first == KeyChord(.delete) {
            stopRecording()
            removed()
        } else {
            stopRecording()
            // The key's own character, as the rules store it.
            recorded(candidates.last!)
        }
        return true
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopRecording()
        super.viewWillMove(toWindow: newWindow)
    }

    override var isHidden: Bool {
        didSet { if isHidden { stopRecording() } }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { stopRecording() }
            needsDisplay = true
        }
    }
}
