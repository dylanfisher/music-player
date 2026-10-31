import AppKit
import DisplayText

/// A palette row: the kind's icon, the title with its matched letters bold, the detail in
/// secondary text, and a command's chord right-aligned. A long title wraps and the row grows.
@MainActor
final class PaletteRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PaletteRow")
    static let minimumHeight = 32.0
    private static let side = 16.0
    private static let iconSize = 18.0
    private static let gap = 8.0
    private static let titleFont = NSFont.systemFont(ofSize: 14)
    private static let detailFont = NSFont.systemFont(ofSize: 12)

    private let icon = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let chord = NSTextField(labelWithString: "")
    private var ranked: RankedItem?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        detail.font = Self.detailFont
        detail.lineBreakMode = .byTruncatingTail
        chord.font = Self.detailFont
        chord.alignment = .right
        for view in [icon, title, detail, chord] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    func show(_ ranked: RankedItem) {
        self.ranked = ranked
        let item = ranked.item
        icon.image = NSImage(
            systemSymbolName: Self.symbol(item.kind), accessibilityDescription: nil)
        title.attributedStringValue = Self.title(ranked)
        detail.stringValue = item.detail ?? ""
        chord.stringValue = item.chord ?? ""
        updateColors()
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let enabled = ranked?.item.isEnabled ?? true
        let primary: NSColor =
            selected
            ? .alternateSelectedControlTextColor : enabled ? .labelColor : .tertiaryLabelColor
        let secondary: NSColor =
            selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        title.textColor = primary
        if let ranked {
            let text = NSMutableAttributedString(attributedString: Self.title(ranked))
            text.addAttribute(
                .foregroundColor, value: primary, range: NSRange(location: 0, length: text.length))
            title.attributedStringValue = text
        }
        icon.contentTintColor = secondary
        detail.textColor = secondary
        chord.textColor = secondary
    }

    override func layout() {
        super.layout()
        guard let ranked else { return }
        let metrics = Self.metrics(ranked, width: bounds.width)
        let middle = bounds.height / 2
        icon.frame = NSRect(
            x: Self.side, y: middle - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize
        )
        var x = Self.side + Self.iconSize + Self.gap
        title.frame = NSRect(
            x: x, y: (bounds.height - metrics.titleHeight) / 2, width: metrics.titleWidth,
            height: metrics.titleHeight)
        x += metrics.titleWidth + Self.gap
        detail.frame = NSRect(x: x, y: middle - 8, width: metrics.detailWidth, height: 16)
        chord.frame = NSRect(
            x: bounds.width - Self.side - metrics.chordWidth, y: middle - 8,
            width: metrics.chordWidth, height: 16)
    }

    /// The row's height for `width`, from the title's height where it wraps.
    static func height(of ranked: RankedItem, width: Double) -> Double {
        max(minimumHeight, metrics(ranked, width: width).titleHeight + 14)
    }

    /// The widths the title, detail and chord take; the detail keeps up to a third of the row.
    private static func metrics(_ ranked: RankedItem, width: Double) -> (
        titleWidth: Double, titleHeight: Double, detailWidth: Double, chordWidth: Double
    ) {
        let item = ranked.item
        let chordWidth =
            item.chord.map {
                ceil(($0 as NSString).size(withAttributes: [.font: detailFont]).width) + 8
            } ?? 0
        let room = width - 2 * side - iconSize - 3 * gap - chordWidth
        let detailWidth = min(
            room / 3,
            item.detail.map {
                ceil(($0 as NSString).size(withAttributes: [.font: detailFont]).width) + 8
            } ?? 0)
        let titleWidth = max(40, room - detailWidth)
        let bounds = title(ranked).boundingRect(
            with: NSSize(width: titleWidth, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return (
            titleWidth, ceil(bounds.height) + (bounds.height > 20 ? 3 : 0), detailWidth, chordWidth
        )
    }

    private static func title(_ ranked: RankedItem) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: ranked.item.title, attributes: [.font: titleFont])
        let bold = NSFont.boldSystemFont(ofSize: titleFont.pointSize)
        for range in ranked.highlights where NSMaxRange(range) <= text.length {
            text.addAttribute(.font, value: bold, range: range)
        }
        return text
    }

    private static func symbol(_ kind: PaletteItem.Kind) -> String {
        switch kind {
        case .command: "command"
        case .setting: "gearshape"
        case .playlist: SymbolName.playlist
        case .genre: "guitars"
        case .artist: "music.mic"
        case .album: "square.stack"
        case .track: "music.note"
        }
    }
}
