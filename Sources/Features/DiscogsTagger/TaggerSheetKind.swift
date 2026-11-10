import AppKit
import Settings

/// The kinds of tagger sheet, each of which keeps its own size, column widths, order and sort in
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
    /// Gives the sheet the size, column order, widths and sort it was left at: the size within
    /// its minimum and `room`, the screen's; a column or a sort the sheet no longer has is
    /// ignored.
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
        window.contentView?.layoutSubtreeIfNeeded()
        table.apply(layout.table)
    }

    /// `layouts` with this sheet's as it is now.
    func recorded(in layouts: TaggerSheetLayouts) -> TaggerSheetLayouts {
        guard let window else { return layouts }
        let size = window.contentRect(forFrameRect: window.frame).size
        var recorded = layouts
        recorded[keyPath: Self.layoutKind.layout] = TaggerSheetLayouts.Layout(
            width: Double(size.width), height: Double(size.height), table: table.layout)
        return recorded
    }
}
