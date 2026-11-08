import AppKit
import Settings

/// The kinds of tagger sheet, each of which keeps its own size, column widths and sort in
/// `state.json` (ADR 0136).
enum TaggerSheetKind {
    case otherReleases, viewRelease, viewChanges, fieldMapping

    /// Where `TaggerSheetLayouts` keeps this kind's layout.
    var layout: WritableKeyPath<TaggerSheetLayouts, TaggerSheetLayouts.Layout?> {
        switch self {
        case .otherReleases: \.otherReleases
        case .viewRelease: \.viewRelease
        case .viewChanges: \.viewChanges
        case .fieldMapping: \.fieldMapping
        }
    }
}

extension TaggerSheet {
    /// Gives the sheet the size, widths and sort it was left at: the size within its minimum
    /// and `room`, the screen's; a column or a sort the sheet no longer has is ignored.
    func apply(_ layouts: TaggerSheetLayouts, room: NSSize?) {
        guard let window, let layout = layouts[keyPath: Self.layoutKind.layout] else { return }
        var size = NSSize(
            width: max(layout.width, window.minSize.width),
            height: max(layout.height, window.minSize.height))
        if let room {
            size = NSSize(
                width: min(size.width, max(room.width, window.minSize.width)),
                height: min(size.height, max(room.height, window.minSize.height)))
        }
        window.setContentSize(size)
        // Laid out at the new size first, so the table's resizing to fit it doesn't spread
        // the widths set after.
        window.contentView?.layoutSubtreeIfNeeded()
        for column in table.tableColumns {
            if let width = layout.columns[column.identifier.rawValue] {
                column.width = CGFloat(width)
            }
        }
        if let key = layout.sortColumn,
            table.tableColumns.contains(where: {
                $0.identifier.rawValue == key && $0.sortDescriptorPrototype != nil
            })
        {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: layout.sortAscending)]
        }
    }

    /// `layouts` with this sheet's as it is now.
    func recorded(in layouts: TaggerSheetLayouts) -> TaggerSheetLayouts {
        guard let window else { return layouts }
        let size = window.contentRect(forFrameRect: window.frame).size
        let sort = table.sortDescriptors.first
        var recorded = layouts
        recorded[keyPath: Self.layoutKind.layout] = TaggerSheetLayouts.Layout(
            width: Double(size.width), height: Double(size.height),
            columns: Dictionary(
                uniqueKeysWithValues: table.tableColumns.map {
                    ($0.identifier.rawValue, Double($0.width))
                }),
            sortColumn: sort?.key, sortAscending: sort?.ascending ?? true)
        return recorded
    }
}
