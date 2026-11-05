import AppKit
import Settings

/// How the track table draws: the `appearance.` settings for its lines, rows and art, and
/// whether the window's glass is on, which draws the alternating rows translucent.
public struct TableAppearance: Equatable, Sendable {
    public var columnLines: Bool
    public var rowLines: Bool
    public var albumLines: Bool
    /// The row and column lines' color, and the album lines'; nil is the system's grid color.
    public var rowLineColor: HexColor?
    public var albumLineColor: HexColor?
    /// The playing track's row; nil is `MarkedRowView`'s light gray.
    public var playingRowColor: HexColor?
    public var alternatingRows: Bool
    public var rowHeight: RowHeight
    public var artSize: ArtSize
    public var glass: Bool

    public init(
        columnLines: Bool, rowLines: Bool, albumLines: Bool, rowLineColor: HexColor?,
        albumLineColor: HexColor?, playingRowColor: HexColor?, alternatingRows: Bool,
        rowHeight: RowHeight, artSize: ArtSize, glass: Bool
    ) {
        self.columnLines = columnLines
        self.rowLines = rowLines
        self.albumLines = albumLines
        self.rowLineColor = rowLineColor
        self.albumLineColor = albumLineColor
        self.playingRowColor = playingRowColor
        self.alternatingRows = alternatingRows
        self.rowHeight = rowHeight
        self.artSize = artSize
        self.glass = glass
    }

    var rowLine: NSColor { rowLineColor.map(NSColor.init) ?? .gridColor }
    var albumLine: NSColor { albumLineColor.map(NSColor.init) ?? .gridColor }
    var playingRow: NSColor? { playingRowColor.map(NSColor.init) }
}

extension NSColor {
    /// A color setting's color. The config file refuses text that isn't a color, so this never
    /// sees one.
    fileprivate convenience init(_ hex: HexColor) {
        guard let parts = hex.components else {
            preconditionFailure("\(hex.text) isn't a color but passed the config file's check")
        }
        self.init(srgbRed: parts.red, green: parts.green, blue: parts.blue, alpha: parts.alpha)
    }
}

extension RowHeight {
    /// Compact is Swinsian's row height.
    var points: CGFloat {
        switch self {
        case .compact: 16
        case .regular: RowListController.rowHeight
        case .large: 22
        }
    }

    /// The track table's text: a point larger for each step taller, as large as fits the row.
    var font: NSFont {
        switch self {
        case .compact: TextCell.font
        case .regular: .systemFont(ofSize: 12)
        case .large: .systemFont(ofSize: 13)
        }
    }
}
