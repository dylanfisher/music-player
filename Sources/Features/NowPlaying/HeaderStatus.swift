import AppKit
import BarView
import Settings

/// The toolbar's now-playing status: the playing track's art, title, title line, artist and
/// album, format line, seek bar and rating, laid out in columns as
/// `appearance.headerStatusLayout` says (ADR 0085). A flexible center column takes the width
/// the side columns leave, a stacked column always stacks, and the status is as tall as its
/// tallest column.
@MainActor
public final class HeaderStatus {
    static let spacingPoints = 10.0
    /// Between the lines of a stacked column.
    static let lineSpacingPoints = 1.0
    /// Above a stacked seek bar.
    static let seekSpacingPoints = 2.0

    /// The status, which the toolbar's item shows.
    public let view = NSView()
    let art = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    /// The title, artist and album in one line, as Swinsian's toolbar shows them.
    let titleLineLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let formatLabel = NSTextField(labelWithString: "")
    let seekBox = SeekBox()
    /// In the artist and album's size.
    let rating = RatingStars(fontPoints: NSFont.smallSystemFontSize)
    private let leading = NSStackView()
    private let trailing = NSStackView()
    private let columns = BarColumns()
    private let row: CenteredRow
    private(set) var layout = BarLayout.defaultHeaderStatus

    init() {
        row = CenteredRow(
            leading: leading, middle: columns.center, trailing: trailing,
            spacing: Self.spacingPoints, inset: 0, fillsBeforeCentering: true)
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 3
        art.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        art.translatesAutoresizingMaskIntoConstraints = false
        let artPoints = CGFloat(HeaderPart.artPoints)
        NSLayoutConstraint.activate([
            art.widthAnchor.constraint(equalToConstant: artPoints),
            art.heightAnchor.constraint(equalToConstant: artPoints),
        ])
        for label in [titleLabel, titleLineLabel] {
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        }
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        formatLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        for label in [subtitleLabel, formatLabel] {
            label.textColor = .secondaryLabelColor
        }
        for label in [titleLabel, titleLineLabel, subtitleLabel, formatLabel] {
            label.lineBreakMode = .byTruncatingTail
        }
        for stack in [leading, trailing] {
            stack.detachesHiddenViews = true
            stack.distribution = .fill
            stack.spacing = Self.spacingPoints
            stack.alignment = .centerY
            stack.setHuggingPriority(.init(1), for: .horizontal)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        var fit = [
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.topAnchor.constraint(equalTo: view.topAnchor),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        // The row centers its views on its middle line; these make it as tall as the tallest.
        for edge in [leading, columns.center, trailing] as [NSView] {
            fit += [
                edge.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
                edge.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(fit)
        apply(layout)
    }

    /// Whether the status shows its parts. With nothing playing it shows none, only the
    /// toolbar's background; the hidden row keeps its constraints, so the status keeps its size
    /// and the toolbar doesn't move when a track starts.
    var showsParts: Bool {
        get { !row.isHidden }
        set { row.isHidden = !newValue }
    }

    /// The view that shows `part`.
    func view(for part: HeaderPart) -> NSView {
        switch part {
        case .art: art
        case .title: titleLabel
        case .titleLine: titleLineLabel
        case .subtitle: subtitleLabel
        case .format: formatLabel
        case .seek: seekBox
        case .rating: rating
        }
    }

    /// How wide a status laid out as `layout` is when every column is fixed: the columns'
    /// widths and the spacing between them. Nil when a column is flexible, so the status's
    /// width is the room it's given.
    public static func fixedWidthPoints(of layout: BarLayout<HeaderPart>) -> Double? {
        var total = 0.0
        for (_, column) in layout.columns {
            guard case .fixed(let points) = column.width else { return nil }
            total += Double(points)
        }
        return total + spacingPoints * Double(layout.columns.count - 1)
    }

    /// Lays the status out as `layout` says.
    public func apply(_ layout: BarLayout<HeaderPart>) {
        self.layout = layout
        columns.layOut(
            layout, in: row, leading: leading, trailing: trailing, trailingBefore: nil,
            spacing: Self.spacingPoints, stacks: { layout[$0]?.stacks == true },
            content: { [self] _, column in
                (column.parts.map(view(for:)), column.parts.contains(.seek) ? seekBox : nil)
            })
        for (place, column) in layout.columns {
            guard let stack = columns.column(at: place)?.stack else { continue }
            let views = stack.arrangedSubviews
            for (view, next) in zip(views, views.dropFirst()) {
                stack.setCustomSpacing(
                    !column.stacks
                        ? NSStackView.useDefaultSpacing
                        : next === seekBox ? Self.seekSpacingPoints : Self.lineSpacingPoints,
                    after: view)
            }
        }
        row.spaceEdges(leading: !layout.leading.isEmpty, trailing: !layout.trailing.isEmpty)
    }
}
