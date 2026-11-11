import AppKit
import DisplayText
import Library
import Settings

/// Five stars, as the track table's Rating column draws them: filled up to the rating, or up to
/// the star under the pointer while it hovers. A click rates through `RatingClick`, at once,
/// since the rating is the index's, not the file's. Get Info shows them, and the bars show the
/// playing track's (ADR 0203).
public final class RatingStars: NSView {
    /// The tracks' rating, 0 for unrated; nil when they're rated differently, which shows the
    /// empty stars dimmed.
    public var rating: Int? = 0 {
        didSet { show() }
    }
    /// Turning it off drops a hover, which shows only while the stars can be clicked.
    public var isEnabled = false {
        didSet {
            if !isEnabled { hovered = nil }
            show()
        }
    }
    /// Called with the stars a click gives, 0 to clear.
    public var clicked: (Int) -> Void = { _ in }
    /// The stars the pointer fills while it's over them.
    private(set) var hovered: Int?
    private let font: NSFont
    /// Measured once, since the font doesn't change.
    private lazy var starWidth = font.starWidth

    /// The stars in the system font at `fontPoints`.
    public init(fontPoints: CGFloat) {
        font = .systemFont(ofSize: fontPoints)
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(TrackColumn.rating.title)
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override public var intrinsicContentSize: NSSize {
        NSSize(
            width: starWidth * CGFloat(SmartField.maxRating),
            height: font.boundingRectForFont.height)
    }

    /// A bar in the title bar, or under a glass window's full-size content view, drags the
    /// window from a view that lets it; a click on the stars rates instead, while they take one.
    override public var mouseDownCanMoveWindow: Bool { !isEnabled }

    /// A click in a window that isn't active rates too, as one on the seek bar seeks.
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// How many stars show filled now.
    var filled: Int { hovered ?? rating ?? 0 }

    /// The stars as they show: "★★★☆☆" for three.
    var text: String {
        stars(filled) + String(repeating: emptyStar, count: SmartField.maxRating - filled)
    }

    override public func draw(_ dirtyRect: NSRect) {
        let color: NSColor =
            !isEnabled || (rating == nil && hovered == nil) ? .tertiaryLabelColor : .labelColor
        let width = starWidth
        for (star, glyph) in text.enumerated() {
            (String(glyph) as NSString).draw(
                at: NSPoint(x: CGFloat(star) * width, y: 0),
                withAttributes: [.font: font, .foregroundColor: color])
        }
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self))
    }

    override public func mouseMoved(with event: NSEvent) { hover(atX: x(of: event)) }
    override public func mouseEntered(with event: NSEvent) { hover(atX: x(of: event)) }
    override public func mouseExited(with event: NSEvent) { hover(atX: nil) }
    override public func mouseDown(with event: NSEvent) { click(atX: x(of: event)) }

    private func x(of event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

    /// Fills the stars up to the one at `x`, from the view's left edge; nil when the pointer
    /// left.
    func hover(atX x: CGFloat?) {
        hovered = isEnabled ? x.map { RatingClick.hovered(at: $0, starWidth: starWidth) } : nil
        show()
    }

    /// A click at `x`: the star there, or none on the rating the tracks have. The stars then
    /// show the rating the click gave until the pointer moves.
    func click(atX x: CGFloat) {
        guard isEnabled else { return }
        let stars = RatingClick.stars(at: x, starWidth: starWidth, current: rating)
        hovered = nil
        rating = stars
        clicked(stars)
    }

    private func show() {
        toolTip = rating == nil ? mixedPlaceholder : nil
        setAccessibilityValue(rating == nil ? mixedPlaceholder : stars(rating ?? 0))
        setAccessibilityEnabled(isEnabled)
        needsDisplay = true
    }
}
