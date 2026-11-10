import AppKit
import Settings

extension NSTableView {
    /// Gives the columns the order and widths `layout` has, and its sort when a column sorts by
    /// it; a column the table no longer has is ignored. Call it once the table is laid out at
    /// its size, so the table's resizing to fit doesn't spread the widths set here.
    func apply(_ layout: TableLayout) {
        var place = 0
        for name in layout.order {
            guard let index = tableColumns.firstIndex(where: { $0.identifier.rawValue == name })
            else { continue }
            if index != place { moveColumn(index, toColumn: place) }
            place += 1
        }
        for column in tableColumns {
            if let width = layout.widths[column.identifier.rawValue] {
                column.width = CGFloat(width)
            }
        }
        if let key = layout.sortColumn,
            tableColumns.contains(where: {
                $0.identifier.rawValue == key && $0.sortDescriptorPrototype != nil
            })
        {
            sortDescriptors = [NSSortDescriptor(key: key, ascending: layout.sortAscending)]
        }
    }

    /// The columns' order, widths and sort as they are now.
    var layout: TableLayout {
        let sort = sortDescriptors.first
        return TableLayout(
            widths: Dictionary(
                uniqueKeysWithValues: tableColumns.map {
                    ($0.identifier.rawValue, Double($0.width))
                }),
            order: tableColumns.map(\.identifier.rawValue), sortColumn: sort?.key,
            sortAscending: sort?.ascending ?? true)
    }
}
