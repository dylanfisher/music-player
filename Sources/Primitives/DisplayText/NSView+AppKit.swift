import AppKit

extension NSView {
    /// Replaces the view's tracking areas with one that reports the pointer's moves over what
    /// shows of it while the window is key, for a chart's or list's hover.
    public func trackMouseMoves() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }
}
