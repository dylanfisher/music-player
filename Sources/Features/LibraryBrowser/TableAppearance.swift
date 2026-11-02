import Foundation
import Settings

/// How the track table draws: the `appearance.` settings for its lines, rows and art.
public struct TableAppearance: Equatable, Sendable {
    public var columnLines: Bool
    public var rowLines: Bool
    public var alternatingRows: Bool
    public var rowHeight: RowHeight
    public var artSize: ArtSize

    public init(
        columnLines: Bool, rowLines: Bool, alternatingRows: Bool, rowHeight: RowHeight,
        artSize: ArtSize
    ) {
        self.columnLines = columnLines
        self.rowLines = rowLines
        self.alternatingRows = alternatingRows
        self.rowHeight = rowHeight
        self.artSize = artSize
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
}
