import AppKit

/// An album's whole art at the Album Art column's width, shown over the rows while the pointer
/// is on the art. Placed by frame, as anything over the track table is (ADR 0058). A click on it
/// calls `clicked`.
final class ArtHover: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var clicked: () -> Void = {}

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(
            in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func mouseDown(with event: NSEvent) { clicked() }
}
