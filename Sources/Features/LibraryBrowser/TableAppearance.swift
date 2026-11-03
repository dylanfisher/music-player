import AppKit
import Settings

/// How the track table draws: the `appearance.` settings for its lines, rows and art, and
/// whether the window's glass is on, which draws the alternating rows translucent.
public struct TableAppearance: Equatable, Sendable {
    public var columnLines: Bool
    public var rowLines: Bool
    public var alternatingRows: Bool
    public var rowHeight: RowHeight
    public var artSize: ArtSize
    public var glass: Bool

    public init(
        columnLines: Bool, rowLines: Bool, alternatingRows: Bool, rowHeight: RowHeight,
        artSize: ArtSize, glass: Bool
    ) {
        self.columnLines = columnLines
        self.rowLines = rowLines
        self.alternatingRows = alternatingRows
        self.rowHeight = rowHeight
        self.artSize = artSize
        self.glass = glass
    }
}

extension RowHeight {
    /// Compact is Swinsian's row height.
    var points: CGFloat {
        switch self {
        case .compact: 17
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
