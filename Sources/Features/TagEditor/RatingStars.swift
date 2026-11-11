import AppKit
import DisplayText
import Library
import Settings

/// Get Info's five stars, as the track table's Rating column draws them: filled up to the
/// rating, or up to the star under the pointer while it hovers. A click rates through
/// `RatingClick`, at once, since the rating is the index's, not the file's.
final class RatingStars: NSView {
    /// The tracks' rating, 0 for unrated; nil when they're rated differently, which shows the
    /// empty stars dimmed.
    var rating: Int? = 0 {
        didSet { show() }
    }
    var isEnabled = false {
        didSet { show() }
    }
    /// Called with the stars a click gives, 0 to clear.
    var clicked: (Int) -> Void = { _ in }
    /// The stars the pointer fills while it's over them.
    private(set) var hovered: Int?
    private let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var starWidth: CGFloat {
        (stars(1) as NSString).size(withAttributes: [.font: font]).width
    }

    init() {
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

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: starWidth * CGFloat(SmartField.maxRating),
            height: font.boundingRectForFont.height)
    }

    /// How many stars show filled now.
    var filled: Int { hovered ?? rating ?? 0 }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor =
            !isEnabled || (rating == nil && hovered == nil) ? .tertiaryLabelColor : .labelColor
        let width = starWidth
        for star in 0..<SmartField.maxRating {
            let glyph = star < filled ? stars(1) : emptyStar
            (glyph as NSString).draw(
                at: NSPoint(x: CGFloat(star) * width, y: 0),
                withAttributes: [.font: font, .foregroundColor: color])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hover(atX: x(of: event)) }
    override func mouseEntered(with event: NSEvent) { hover(atX: x(of: event)) }
    override func mouseExited(with event: NSEvent) { hover(atX: nil) }
    override func mouseDown(with event: NSEvent) { click(atX: x(of: event)) }

    private func x(of event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

    /// Fills the stars up to the one at `x`, from the view's left edge; nil when the pointer
    /// left.
    func hover(atX x: CGFloat?) {
        hovered = isEnabled ? x.map { RatingClick.hovered(at: $0, starWidth: starWidth) } : nil
        show()
    }

    /// A click at `x`: the star there, or none on the rating the tracks have.
    func click(atX x: CGFloat) {
        guard isEnabled else { return }
        let stars = RatingClick.stars(at: x, starWidth: starWidth, current: rating)
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

/// An unfilled star, as Get Info draws the stars a rating doesn't reach.
let emptyStar = "☆"
